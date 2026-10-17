# Commute iOS client

## Two modes, one app

| | Standalone (default) | Server |
|---|---|---|
| Trains | Caltrain GTFS timetable, downloaded on first launch and cached | Server realtime, timetable as fallback |
| Delays, cancellations | — | ✓ |
| Leave alerts | Local notifications, scheduled a week ahead | Push notifications from the server |

Switch in Settings → Data source. The timetable refreshes from Settings → Caltrain timetable → Refresh.

## Architecture

The mode decides only two implementations, bundled in `CommuteServices` and built by a
`CommuteServiceFactory`:

| Abstraction | Standalone | Server |
|---|---|---|
| `TransitProvider` | `TimetableTransitProvider` | `FallbackTransitProvider(ServerTransitProvider → TimetableTransitProvider)` |
| `LeaveAlertScheduler` | `LocalLeaveAlertScheduler` | `NoopLeaveAlertScheduler` (the server pushes) |

Everything else (planner, alert planning, UI, settings) is shared. `StandardServiceFactory` is the
only place that knows which implementation goes with which mode; `CommuteViewModel` rebuilds the
services when the data source changes.

### Layout

- `Sources/CommuteCore/`: Foundation-only, tested on macOS
  - `Models/`: stations (Caltrain GTFS ids), train types, profile, data-source settings, plan
  - `Planning/`: `DefaultPlanner` (train + get ready / leave / too late), `LeaveAlertPlanner`
  - `Timetable/`: ZIP reader, CSV and GTFS parsing, `Timetable` queries, `TimetableStore` (memory + disk cache, download on first use)
  - `Providers/`: provider protocols, timetable / server / fallback providers, `CommuteServices` factory, fixed and sample providers for tests and previews
  - `Storage/`: profile persistence, departed-commute log
- `Sources/CommuteKit/`: Apple-platform layer, re-exports `CommuteCore`
  - `MapKit/`: car ETAs and travel-time estimates from Apple Maps
  - `Notifications/`: local leave alerts
  - `Presentation/`: map with a bottom-sheet plan, settings, address search
- `Tests/CommuteCoreTests/`: planner, timetable (with a miniature GTFS fixture), services, alerts
- `CommuteApp/`: the Xcode app target; `CommuteAppApp.swift` wires the implementations

## Planning rules

- Travel times are minutes you set per place (door ↔ platform), with an Apple Maps estimate to start from.
- Target train: the first train of a preferred type you catch, with the safety buffer, when leaving at
  the target time (morning: leave home; evening: leave work).
- Too late = departure − minutes to the platform. Leave = too late − safety buffer. Get ready = leave − prep time.
- Once the target train is too late, the plan rolls to the next catchable train.
- Door arrival = train arrival + minutes from the destination platform.

## Run

```bash
cd client
swift test                       # core tests
CALTRAIN_GTFS=~/Downloads/caltrain-ca-us.zip swift test --filter RealFeedTests   # optional: parse a real feed
open CommuteApp/CommuteApp.xcodeproj
```

Debug launch arguments (scheme → Run → Arguments) for screenshots and testing:

```
-debugNow 2026-10-19T07:45:00-07:00   # fixed clock that then ticks
-debugPanel peek|medium|large         # initial sheet size
-debugSettings YES                    # open Settings once loaded
```

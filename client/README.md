# Commute iOS client

## Two modes, one app

| | Standalone (default) | Server |
|---|---|---|
| Trains | Caltrain GTFS timetable, downloaded on first launch and cached | Server realtime, timetable as fallback |
| Delays, cancellations | ✓ Caltrain's public JSON feed, fetched only within 90 min of a trip, at most every 3 min (30 s on manual refresh), 5 min backoff after errors | ✓ |
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
- `CommuteApp/CommuteWidgets/`: widget extension with the Lock Screen / Dynamic Island Live Activity

## Planning rules

- Travel times are minutes you set per place (door ↔ platform), with an Apple Maps estimate to start from.
- Target train: the first train of a preferred type you catch, with the safety buffer, when leaving at
  the target time (morning: leave home; evening: leave work).
- Too late = departure − minutes to the platform. Leave = too late − safety buffer. Get ready = leave − prep time.
- Once the target train is too late, the plan rolls to the next catchable train.
- The schedule shows every train type. Touch and hold a catchable train, then choose **Pin this train**
  to follow it for this trip. Touch and hold the selected train and choose **Unpin**
  to clear the override.
  A manual target expires when it can no longer be caught or its commute window ends.
- Two modes, switched with the control at the top left. **Commute** plans leaving home and work as above.
  **Schedule** shows the next trains between any two stations (tap either station name to change it,
  ⇆ swaps them), with no travel time or buffer; the stations are remembered. The app opens in Commute
  from two hours before a target leave time until its four-hour window ends, on commute days that
  aren't holidays, and in Schedule otherwise. A switch by hand lasts until that changes or the app
  returns from the background. Alerts, location tracking and the Lock Screen countdown follow the
  commute in either mode. Settings is the gear in the sheet header.
- Automatic selection rolls forward for four hours after the target leave time, then moves to
  the next commute. Late evening windows continue across midnight. Tomorrow’s trains are labeled.
- With location access (while using the app), leaving the starting place during a trip marks it as
  departed: the card shows "You're on your way" / "You're on the train" and that trip's alerts stop.
  Without access, nothing changes.
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
-debugPanel collapsed|expanded       # initial sheet position
-debugSettings YES                    # open Settings once loaded
```

# Commute iOS client

## Two modes, one app

| | Standalone (default) | Server |
|---|---|---|
| Trains | Caltrain GTFS timetable, downloaded on first launch and cached | Server realtime, timetable as fallback |
| Delays, cancellations | ✓ Caltrain's public JSON feed, fetched only within 90 min of a trip, at most every 3 min (30 s on manual refresh), 5 min backoff after errors | ✓ |
| Leave alerts | Local notifications, scheduled a week ahead | Push notifications from the server |

Settings only offers standalone; server mode stays in the code but is reachable only through a saved profile, and saving Settings returns to standalone. The timetable refreshes from Settings → Train data → Refresh.

## Architecture

The mode decides only two implementations, bundled in `CommuteServices` and built by a
`CommuteServiceFactory`:

| Abstraction | Standalone | Server |
|---|---|---|
| `TransitProvider` | `LiveTimetableTransitProvider` (timetable + `CaltrainLiveFeed` delays) | `FallbackTransitProvider(ServerTransitProvider → TimetableTransitProvider)` |
| `LeaveAlertScheduler` | `LocalLeaveAlertScheduler` | `NoopLeaveAlertScheduler` (the server pushes) |

Everything else (planner, alert planning, UI, settings) is shared. `StandardServiceFactory` is the
only place that knows which implementation goes with which mode; `CommuteViewModel` rebuilds the
services when the data source changes.

### Layout

- `Sources/CommuteCore/`: Foundation-only, tested on macOS
  - `Models/`: stations (Caltrain GTFS ids), train types, profile, data-source settings, plan
  - `Planning/`: `DefaultPlanner` (train + get ready / leave / too late), `CommuteWindow` (which trip and mode is current), `TripRecord` (trips under way, their train, when they're over), `DepartureDetection`, `LeaveAlertPlanner`
  - `Timetable/`: ZIP reader, CSV and GTFS parsing, `Timetable` queries, `TimetableStore` (memory + disk cache, download on first use)
  - `Providers/`: provider protocols, timetable / server / fallback providers, `CommuteServices` factory, fixed and sample providers for tests and previews
  - `Storage/`: profile persistence, the trip log behind `TripRecord`
- `Sources/CommuteKit/`: Apple-platform layer, re-exports `CommuteCore`
  - `MapKit/`: car ETAs and travel-time estimates from Apple Maps
  - `Notifications/`: local leave alerts
  - `Presentation/`: `CommuteViewModel`, the map, the bottom sheet (`PlanPanel` with `HeroCard`, `UpcomingTrainsCard`, `StopList`, `CarCard`), settings, address search
- `Tests/CommuteCoreTests/`: planner, timetable (with a miniature GTFS fixture), services, alerts
- `CommuteApp/`: the Xcode app target; `CommuteAppApp.swift` wires the implementations
- `CommuteApp/CommuteWidgets/`: widget extension with the Lock Screen / Dynamic Island Live Activity

## Planning rules

- Commute needs both home and work addresses (Settings → Places). Without them the app shows only Schedule,
  with a notice under the card; tapping Commute explains why. Alerts and the Lock Screen countdown stay off
  until both are set. The map draws home and work only for addresses away from their stations.
- Travel times are minutes you set per place (door ↔ platform), with an Apple Maps estimate to start from.
- Target train: the first train of a preferred type you catch, with the safety buffer, when leaving at
  the target time (morning: leave home; evening: leave work).
- Too late = departure − minutes to the platform. Leave = too late − safety buffer. Get ready = leave − prep time.
- Once the target train is too late, the plan rolls to the next catchable train.
- The schedule shows every train type; types turned off in Settings say **Skipped** (the ⓘ by the
  list title explains). Touch and hold a train you can still leave for, then choose **Pin this train**
  to follow it for this trip. Touch and hold the selected train and choose **Unpin**
  to clear the override.
  A manual target expires when it can no longer be caught or its commute window ends.
- Two modes, switched with the control at the top left. **Commute** plans leaving home and work as above.
  **Schedule** shows the next trains between any two stations (tap either station name to change it),
  with no travel time or buffer; the stations are remembered. The pill at the top right names the timetable
  on screen (Weekday, Weekend or Holiday); in Schedule a tap flips to the other one, showing the next
  such day at the same time, and back to today. In Commute it's only a label. The arrow between the card's times
  switches direction in Commute and swaps the stations in Schedule; refresh is at the left of the header. The app opens in Commute
  from two hours before a target leave time until its four-hour window ends, on commute days that
  aren't holidays, and in Schedule otherwise. A switch by hand lasts until that changes or the app
  returns from the background. Alerts, location tracking and the Lock Screen countdown follow the
  commute in either mode. Settings is the gear in the sheet header.
- Automatic selection rolls forward for four hours after the target leave time, then moves to
  the next commute. Late evening windows continue across midnight. Tomorrow’s trains are labeled.
- **On my way** (on the card within 90 minutes of the train) or **I’m taking this train** (touch and hold
  a row once it's time to leave for it, even one that already left; earlier rows offer Pin instead) marks the trip by hand; **End trip** undoes it. Settings → Location
  → **Notice when I leave** turns automatic detection on or off; off, location is never used.
- With location access (while using the app), leaving the starting place during a trip marks it as
  departed: the card shows "You're on your way" / "You're on the train" and that trip's alerts stop.
  Without access, nothing changes.
- Door arrival = train arrival + minutes from the destination platform.

## Card states

The next-train card in Commute mode, for a trip leaving home at 8:00 on the 8:20 (16 min to the
station, 3 min buffer, 20 min prep). The same applies to the evening trip from work.

| State | When | Card |
|---|---|---|
| On track (green) | before get ready | "Leave in 31 min · by 8:01 AM" |
| Get ready (amber) | from leave − prep (7:41) | same line, amber |
| Leave soon / Leave now (red) | from 3 min before leaving (7:58) / at leave time (8:01) | then "Too late in 2 min · at 8:04 AM" |
| Missed it! (red) | for 10 s once too late (8:04) | "Next: Local 114 at 8:25 AM", then the plan moves to that train |
| You're on your way | trip marked (On my way, a row, or location) before the train leaves | "Train in 14 min · departs 8:20 AM", End trip |
| You're on the train | from departure | next stop line, "Arrives in 19 min", the map arrow moves |
| Your stop is next | one stop before | plus a notification a few minutes before arriving |
| Almost there | from the train's arrival | "At work in 10 min · 9:09 AM" |
| Next trip | from door arrival | the evening trip home, back at On track |
| Next train (blue) | away from home or work with no trip under way, e.g. after End trip | "Departs in 4 min", On this train |

Schedule mode shows "Next train · Departs in…" for the chosen stations, with the train after it.
`-debugNow <ISO 8601>`, `-debugTrip <number|none|ended>` and `-debugPanel compact|expanded` launch
options reproduce each state in the simulator.

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

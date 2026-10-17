# Commute iOS client

## Layout

- `Sources/CommuteCore/`: Foundation-only domain, testable on macOS
  - `Models/`: stations (Caltrain GTFS ids), train types, profile, plan
  - `Planning/CommutePlanner.swift`: picks the train and the get ready / leave / too late times
  - `Providers/`: provider protocols, `SampleTransitProvider` (generated Caltrain-like day), fixed test doubles
  - `Storage/`: profile persistence (`UserDefaults`)
- `Sources/CommuteKit/`: Apple-platform layer, re-exports `CommuteCore`
  - `MapKit/`: car ETAs and station access times from Apple Maps
  - `Presentation/`: map with a bottom-sheet plan, settings, address search
- `Tests/CommuteCoreTests/`: planner, model and sample-schedule tests
- `CommuteApp/`: the Xcode app target; it composes providers in `CommuteAppApp.swift`

## Planning rules

- Target train: the first train of a preferred type you catch, with the safety buffer, when leaving at
  the target time (morning: leave home; evening: leave work).
- Too late = departure − (ride or walk + platform time). Leave = too late − safety buffer.
  Get ready = leave − prep time.
- Once the target train is too late, the plan rolls to the next catchable train.
- Bike time = Apple Maps walking-route distance at your bike speed (MapKit has no cycling mode);
  straight-line estimate if routing fails.

Train data is a generated sample until the server exists; swap `SampleTransitProvider`
for a server-backed `TransitProvider`.

## Run

```bash
cd client
swift test                       # core tests
open CommuteApp/CommuteApp.xcodeproj
```

Debug launch arguments (scheme → Run → Arguments) for screenshots and testing:

```
-debugNow 2026-10-19T07:45:00-07:00   # fixed clock that then ticks
-debugPanel peek|medium|large         # initial sheet size
-debugSettings YES                    # open Settings
```

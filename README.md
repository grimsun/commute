# Commute

Commute is an iOS app for planning trips between home and work.

It compares two commute options:
- Car
- Bike + Train + Bike

The app is designed to help decide:
- when traffic is good enough to drive
- what the next feasible train is
- when to start getting ready
- when to leave
- when it is too late for the current train and you should take the next one

It also supports notification-oriented planning with three key attempt times:
- Get ready
- Leave now
- Too late (roll to next train)

## Current Status

Phase 1 is implemented:
- project foundation and architecture layers (`Domain`, `Data`, `Presentation`)
- core planning models and protocols
- mocked planner and mocked providers
- SwiftUI dashboard and timeline UI
- unit tests for planner behavior

## Project Structure

- `CommuteApp/`: iOS app target (SwiftUI)
- `Sources/CommuteKit/`: core app library
  - `Domain/`: business models, rules, planner
  - `Data/`: providers and storage abstractions (mock implementations in Phase 1)
  - `Presentation/`: view models and SwiftUI views
- `Tests/CommuteKitTests/`: planner tests

## Run

### In Xcode (recommended)

1. Open `CommuteApp/CommuteApp.xcodeproj`.
2. Ensure local package dependency points to this repository and includes product `CommuteKit`.
3. Select an iPhone simulator.
4. Run with `Cmd+R`.

### Tests

```bash
swift test
```

## Roadmap

- Phase 2: real Apple Maps traffic/bike adapters + GTFS train feed integration
- Phase 3: notification scheduling engine and background refresh behavior
- Phase 4: hardening, broader tests, stale-data UX, telemetry hooks

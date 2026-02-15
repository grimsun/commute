# Commute Phase 1

Phase 1 implements the core architecture and mocked end-to-end planning flow:

- `Sources/CommuteKit/Domain`: models, protocols, planner logic.
- `Sources/CommuteKit/Data`: mock providers and in-memory profile store.
- `Sources/CommuteKit/Presentation`: dashboard view model and SwiftUI views.
- `Tests/CommuteKitTests`: planner unit tests.

## Run tests

```bash
swift test
```

## Open in Xcode

1. Open `Package.swift` in Xcode.
2. Use SwiftUI previews for `DashboardView`.
3. For a full iOS app target, create an iOS App in Xcode and import `CommuteKit`.

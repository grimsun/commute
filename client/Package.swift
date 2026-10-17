// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Commute",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "CommuteKit",
            targets: ["CommuteKit"]
        ),
        .library(
            name: "CommuteCore",
            targets: ["CommuteCore"]
        )
    ],
    targets: [
        // Foundation-only domain: models, planner, provider protocols, storage.
        .target(
            name: "CommuteCore",
            path: "Sources/CommuteCore"
        ),
        // Apple-platform layer: MapKit providers and SwiftUI presentation.
        .target(
            name: "CommuteKit",
            dependencies: ["CommuteCore"],
            path: "Sources/CommuteKit"
        ),
        .testTarget(
            name: "CommuteCoreTests",
            dependencies: ["CommuteCore"],
            path: "Tests/CommuteCoreTests"
        )
    ]
)

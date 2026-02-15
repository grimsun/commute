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
        )
    ],
    targets: [
        .target(
            name: "CommuteKit",
            path: "Sources/CommuteKit"
        ),
        .testTarget(
            name: "CommuteKitTests",
            dependencies: ["CommuteKit"],
            path: "Tests/CommuteKitTests"
        )
    ]
)

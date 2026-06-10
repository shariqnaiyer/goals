// swift-tools-version: 5.9
import PackageDescription

// GoalsCore is the pure domain layer described in docs/PLAN.md §3.1.
// It deliberately has NO dependency on SwiftUI, SwiftData, UIKit or any
// Apple-platform-only framework, so it compiles and unit-tests on any
// platform (including Linux CI) and runs identically in tests and the app.
let package = Package(
    name: "GoalsCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "GoalsCore", targets: ["GoalsCore"])
    ],
    targets: [
        .target(
            name: "GoalsCore"
        ),
        .testTarget(
            name: "GoalsCoreTests",
            dependencies: ["GoalsCore"]
        )
    ]
)

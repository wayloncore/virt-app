// swift-tools-version:5.9
import PackageDescription

// VirtCore: Virt's logic with no UI (the bridge messages, the timer math, the alert plan, which pages open in the app).
// Foundation only, so it builds and tests on Linux as well as on a Mac.
let package = Package(
    name: "VirtCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "VirtCore", targets: ["VirtCore"])],
    targets: [
        .target(name: "VirtCore"),
        .testTarget(name: "VirtCoreTests", dependencies: ["VirtCore"]),
    ]
)

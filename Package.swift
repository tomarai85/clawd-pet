// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "clawd-pet",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ClawdCore", targets: ["ClawdCore"]),
        .executable(name: "clawd-pet-agent", targets: ["ClawdAgent"]),
        .executable(name: "clawd-release-probe", targets: ["ClawdReleaseProbe"]),
        .executable(name: "clawd-own-pids", targets: ["ClawdOwnPids"]),
        .executable(name: "clawd-measure-cpu", targets: ["ClawdMeasureCPU"]),
        .executable(name: "clawd-attended-sampler", targets: ["ClawdAttendedSampler"])
    ],
    dependencies: [.package(path: "Vendor/SwiftTerm")],
    targets: [
        .target(name: "ClawdProcess", publicHeadersPath: "include"),
        .target(name: "ClawdCore", dependencies: ["ClawdProcess"]),
        .target(name: "ClawdRendering", dependencies: ["ClawdCore"]),
        .target(name: "ClawdAudio", dependencies: ["ClawdCore"]),
        .target(name: "ClawdDesktop", dependencies: ["ClawdCore", "ClawdRendering", "ClawdAudio", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .executableTarget(name: "ClawdAgent", dependencies: ["ClawdDesktop"]),
        .executableTarget(name: "ClawdReleaseProbe", dependencies: ["ClawdAudio"]),
        .executableTarget(name: "ClawdOwnPids", dependencies: ["ClawdCore"]),
        .executableTarget(name: "ClawdMeasureCPU", dependencies: ["ClawdCore"]),
        // Read-only observer for scripts/attended-check.sh and scripts/post-install-check.sh. It is under Sources/, so the production
        // lint scans it; the agent never links it.
        .executableTarget(name: "ClawdAttendedSampler"),
        // A non-platform process for the chat bridge tests (the system tools hide their environment from the token sweep). Not a product.
        .executableTarget(name: "ClawdChatStub", path: "Tests/ChatStub"),
        // The executables are test dependencies so `swift test` always runs against freshly built binaries.
        .testTarget(
            name: "ClawdCoreTests",
            dependencies: ["ClawdProcess", "ClawdCore", "ClawdRendering", "ClawdAudio", "ClawdDesktop",
                           "ClawdAgent", "ClawdOwnPids", "ClawdReleaseProbe", "ClawdMeasureCPU", "ClawdChatStub",
                           .product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Tests/ClawdCoreTests"
        )
    ]
)

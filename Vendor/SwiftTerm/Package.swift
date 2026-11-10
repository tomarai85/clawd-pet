// swift-tools-version:6.2
// Clawd's vendored SwiftTerm (migueldeicaza/SwiftTerm v1.99.1, commit 2f573f73af5e768d90847dce20c97fa9535d7164): one library, macOS only,
// no dependencies, no traits, no build plugin. See PATCHES.md for everything that differs from upstream.
import PackageDescription

let package = Package(
    name: "SwiftTerm",
    platforms: [.macOS(.v13)],
    products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])],
    targets: [
        .target(
            name: "SwiftTerm",
            path: "Sources/SwiftTerm",
            exclude: ["Apple/Metal/Shaders.metal"]
        )
    ],
    swiftLanguageModes: [.v6]
)

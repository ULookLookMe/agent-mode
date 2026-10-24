// swift-tools-version: 6.4
import PackageDescription

// The Command Line Tools ship the swift-testing macro plugin outside SwiftPM's default plugin search path.
let cltTestingPlugins = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"

let package = Package(
    name: "agentmode",
    platforms: [.macOS(.v27)],
    products: [
        .executable(name: "agentmode", targets: ["agentmode"])
    ],
    targets: [
        .target(name: "AgentModeCore"),
        // Private IOKit HID declarations for the temperature sensors (design §8.4).
        .target(
            name: "CIOHIDPrivate",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "agentmode",
            dependencies: ["AgentModeCore", "CIOHIDPrivate"]
        ),
        .testTarget(
            name: "AgentModeCoreTests",
            dependencies: ["AgentModeCore"],
            swiftSettings: [.unsafeFlags(["-plugin-path", cltTestingPlugins])]
        ),
    ]
)

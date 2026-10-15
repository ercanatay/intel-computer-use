// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IntelComputerUse",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "intel-computer-use-native", targets: ["NativeHelper"]),
        .executable(name: "bridge-core-checks", targets: ["BridgeCoreChecks"]),
        .executable(name: "compatibility-checks", targets: ["CompatibilityChecks"]),
        .executable(name: "intel-computer-use-compat", targets: ["CompatibilityCLI"])
    ],
    targets: [
        .target(name: "BridgeCore"),
        .target(name: "CompatibilityProtocol"),
        .target(name: "CompatibilityRuntime", dependencies: ["CompatibilityProtocol", "BridgeCore"], path: "Sources/CompatibilityService"),
        .executableTarget(name: "CompatibilityCLI", dependencies: ["CompatibilityRuntime"]),
        .executableTarget(name: "CompatibilityChecks", dependencies: ["CompatibilityProtocol", "CompatibilityRuntime", "BridgeCore"], path: "Tests/CompatibilityChecks"),
        .executableTarget(name: "NativeHelper", dependencies: ["BridgeCore"]),
        .executableTarget(name: "BridgeCoreChecks", dependencies: ["BridgeCore"], path: "Tests/BridgeCoreTests")
    ],
    swiftLanguageModes: [.v5]
)

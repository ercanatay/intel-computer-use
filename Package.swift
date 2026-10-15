// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IntelComputerUse",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "intel-computer-use-native", targets: ["NativeHelper"]),
        .executable(name: "bridge-core-checks", targets: ["BridgeCoreChecks"])
    ],
    targets: [
        .target(name: "BridgeCore"),
        .executableTarget(name: "NativeHelper", dependencies: ["BridgeCore"]),
        .executableTarget(name: "BridgeCoreChecks", dependencies: ["BridgeCore"], path: "Tests/BridgeCoreTests")
    ],
    swiftLanguageModes: [.v5]
)

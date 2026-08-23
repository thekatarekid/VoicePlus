// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoicePlus",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VoicePlusApp", targets: ["VoicePlusApp"]),
        .library(name: "Shared", targets: ["Shared"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.1.0"),
    ],
    targets: [
        .target(
            name: "Shared",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            path: "Shared"
        ),
        .target(
            name: "Engine",
            dependencies: ["Shared", .product(name: "FluidAudio", package: "FluidAudio")],
            path: "Engine"
        ),
        .target(name: "Pipeline", dependencies: ["Shared"], path: "Pipeline"),
        .target(name: "Injection", dependencies: ["Shared"], path: "Injection"),
        .target(name: "Providers", dependencies: ["Shared"], path: "Providers"),
        .target(name: "Lab", dependencies: ["Shared"], path: "Lab"),
        .target(name: "Actions", dependencies: ["Shared"], path: "Actions"),
        .executableTarget(
            name: "VoicePlusApp",
            dependencies: ["Shared", "Engine", "Pipeline", "Injection", "Providers", "Lab", "Actions"],
            path: "App"
        ),
        .testTarget(name: "SharedTests", dependencies: ["Shared"], path: "Tests/SharedTests"),
        .testTarget(name: "EngineTests", dependencies: ["Engine"], path: "Tests/EngineTests"),
        .testTarget(name: "PipelineTests", dependencies: ["Pipeline"], path: "Tests/PipelineTests"),
        .testTarget(name: "InjectionTests", dependencies: ["Injection"], path: "Tests/InjectionTests"),
        .testTarget(name: "ProvidersTests", dependencies: ["Providers"], path: "Tests/ProvidersTests"),
        .testTarget(name: "LabTests", dependencies: ["Lab"], path: "Tests/LabTests"),
        .testTarget(name: "ActionsTests", dependencies: ["Actions"], path: "Tests/ActionsTests"),
        .testTarget(name: "AppTests", dependencies: ["Shared"], path: "Tests/AppTests"),
    ],
    swiftLanguageVersions: [.v5]
)

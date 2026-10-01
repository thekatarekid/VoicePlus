// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoicePlus",
    platforms: [.macOS("15.0")],  // V5 J7 floor. `.v15` needs tools-version 6.0; the string form keeps 5.9.
    products: [
        .executable(name: "VoicePlusApp", targets: ["VoicePlusApp"]),
        .library(name: "Shared", targets: ["Shared"]),
        .library(name: "Pipeline", targets: ["Pipeline"]),
        .library(name: "KeyboardCore", targets: ["KeyboardCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        // V5 J6: pinned to main past v0.17.4 — first revision exposing `AsrModelVersion.ultra/.redux`
        // AND `LocalVqeManager` (Apache-2.0). Root revision pin overrides FluidUse's `from: 0.15.8`.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", revision: "c388107348134698135cfd34f3f59dc823b6e7ce"),
        // V5 J6: FluidUse (Apache-2.0) — decision/CUA managers (Laya, Kev, CUA-S1). Main past v0.3.0
        // (KevFastManager is not in a tag yet).
        .package(url: "https://github.com/FluidInference/FluidUse.git", revision: "c9e967f2d6f98b138240c187e49997ef4f60aebe"),
    ],
    targets: [
        .target(
            name: "Shared",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            path: "Shared"
        ),
        .target(
            name: "Engine",
            dependencies: [
                "Shared",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "FluidUse", package: "FluidUse"),
            ],
            path: "Engine"
        ),
        .target(name: "Pipeline", dependencies: ["Shared"], path: "Pipeline"),
        .target(name: "Injection", dependencies: ["Shared"], path: "Injection"),
        .target(name: "Providers", dependencies: ["Shared"], path: "Providers"),
        .target(name: "Lab", dependencies: ["Shared"], path: "Lab"),
        .target(
            name: "Actions",
            dependencies: ["Shared", .product(name: "FluidUse", package: "FluidUse")],
            path: "Actions"
        ),
        .target(name: "Sync", dependencies: ["Shared"], path: "Sync"),
        .target(name: "KeyboardCore", dependencies: ["Shared"], path: "iOS/KeyboardCore"),
        .executableTarget(
            name: "VoicePlusApp",
            dependencies: ["Shared", "Engine", "Pipeline", "Injection", "Providers", "Lab", "Actions", "Sync"],
            path: "App"
        ),
        .testTarget(name: "SharedTests", dependencies: ["Shared"], path: "Tests/SharedTests"),
        .testTarget(name: "EngineTests", dependencies: ["Engine"], path: "Tests/EngineTests"),
        .testTarget(name: "PipelineTests", dependencies: ["Pipeline"], path: "Tests/PipelineTests"),
        .testTarget(name: "InjectionTests", dependencies: ["Injection"], path: "Tests/InjectionTests"),
        .testTarget(name: "ProvidersTests", dependencies: ["Providers"], path: "Tests/ProvidersTests"),
        .testTarget(name: "LabTests", dependencies: ["Lab"], path: "Tests/LabTests"),
        .testTarget(name: "ActionsTests", dependencies: ["Actions"], path: "Tests/ActionsTests"),
        .testTarget(name: "SyncTests", dependencies: ["Sync"], path: "Tests/SyncTests"),
        .testTarget(name: "KeyboardCoreTests", dependencies: ["KeyboardCore"], path: "Tests/KeyboardCoreTests"),
        .testTarget(name: "AppTests", dependencies: ["Shared", "Sync", "VoicePlusApp"], path: "Tests/AppTests"),
    ],
    swiftLanguageVersions: [.v5]
)

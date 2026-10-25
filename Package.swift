// swift-tools-version:6.0
import PackageDescription

let commonSettings: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency"),
]

let v1Modules: [Target.Dependency] = [
    "DeskvanicCore", "DeskvanicUIShared", "DeskvanicCommandCenter", "DeskvanicQuickTools",
    "DeskvanicClipVault", "DeskvanicCapture", "DeskvanicFileStudio", "DeskvanicVault", "DeskvanicClean",
    "DeskvanicGuide", "DeskvanicMedia", "DeskvanicNearLink", "DeskvanicPaper", "DeskvanicWeb", "DeskvanicSessionDock", "DeskvanicVoice", "DeskvanicFlow",
]

let package = Package(
    name: "Deskvanic",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DeskvanicApp", targets: ["DeskvanicApp"]),
        .library(name: "DeskvanicCore", targets: ["DeskvanicCore"]),
    ],
    targets: [
        .executableTarget(
            name: "DeskvanicApp",
            dependencies: v1Modules,
            path: "Sources/DeskvanicApp",
            swiftSettings: commonSettings
        ),
        .target(
            name: "DeskvanicCore",
            path: "Sources/DeskvanicCore",
            swiftSettings: commonSettings
        ),
        .target(
            name: "DeskvanicUIShared",
            dependencies: ["DeskvanicCore"],
            path: "Sources/DeskvanicUIShared",
            swiftSettings: commonSettings
        ),
        .target(
            name: "DeskvanicCommandCenter",
            dependencies: ["DeskvanicCore", "DeskvanicUIShared"],
            path: "Sources/DeskvanicCommandCenter",
            swiftSettings: commonSettings
        ),
        .target(
            name: "DeskvanicQuickTools",
            dependencies: ["DeskvanicCore", "DeskvanicUIShared"],
            path: "Sources/DeskvanicQuickTools",
            swiftSettings: commonSettings
        ),
        .target(
            name: "DeskvanicClipVault",
            dependencies: ["DeskvanicCore", "DeskvanicUIShared"],
            path: "Sources/DeskvanicClipVault",
            swiftSettings: commonSettings
        ),
        .target(
            name: "DeskvanicCapture",
            dependencies: ["DeskvanicCore", "DeskvanicUIShared"],
            path: "Sources/DeskvanicCapture",
            swiftSettings: commonSettings
        ),
        .target(
            name: "DeskvanicFileStudio",
            dependencies: ["DeskvanicCore", "DeskvanicUIShared"],
            path: "Sources/DeskvanicFileStudio",
            swiftSettings: commonSettings
        ),
        .target(
            name: "DeskvanicClean",
            dependencies: ["DeskvanicCore", "DeskvanicUIShared"],
            path: "Sources/DeskvanicClean",
            swiftSettings: commonSettings
        ),
        .target(
            name: "DeskvanicVoice",
            dependencies: ["DeskvanicCore", "DeskvanicUIShared"],
            path: "Sources/DeskvanicVoice",
            swiftSettings: commonSettings
        ),
        .target(
            name: "DeskvanicFlow",
            dependencies: ["DeskvanicCore", "DeskvanicUIShared"],
            path: "Sources/DeskvanicFlow",
            swiftSettings: commonSettings
        ),
        .target(
            name: "DeskvanicPaper",
            dependencies: ["DeskvanicCore", "DeskvanicUIShared", "DeskvanicCapture"],
            path: "Sources/DeskvanicPaper",
            swiftSettings: commonSettings
        ),
        .target(
            name: "DeskvanicWeb",
            dependencies: ["DeskvanicCore", "DeskvanicUIShared"],
            path: "Sources/DeskvanicWeb",
            swiftSettings: commonSettings
        ),
        .target(
            name: "DeskvanicGuide",
            dependencies: ["DeskvanicCore", "DeskvanicUIShared", "DeskvanicCapture"],
            path: "Sources/DeskvanicGuide",
            swiftSettings: commonSettings
        ),
        .target(
            name: "DeskvanicMedia",
            dependencies: ["DeskvanicCore", "DeskvanicUIShared"],
            path: "Sources/DeskvanicMedia",
            swiftSettings: commonSettings
        ),
        .target(
            name: "DeskvanicSessionDock",
            dependencies: ["DeskvanicCore", "DeskvanicUIShared"],
            path: "Sources/DeskvanicSessionDock",
            swiftSettings: commonSettings
        ),
        .target(
            name: "DeskvanicNearLink",
            dependencies: ["DeskvanicCore", "DeskvanicUIShared", "DeskvanicQuickTools"],
            path: "Sources/DeskvanicNearLink",
            swiftSettings: commonSettings
        ),
        .target(
            name: "DeskvanicVault",
            dependencies: ["DeskvanicCore", "DeskvanicUIShared"],
            path: "Sources/DeskvanicVault",
            swiftSettings: commonSettings
        ),
        .testTarget(
            name: "DeskvanicCoreTests",
            dependencies: ["DeskvanicCore"],
            path: "Tests/DeskvanicCoreTests",
            swiftSettings: commonSettings
        ),
        .testTarget(
            name: "DeskvanicModuleTests",
            dependencies: [
                "DeskvanicCore", "DeskvanicCommandCenter", "DeskvanicQuickTools",
                "DeskvanicClipVault", "DeskvanicCapture", "DeskvanicFileStudio", "DeskvanicVault",
                "DeskvanicClean", "DeskvanicGuide", "DeskvanicMedia", "DeskvanicNearLink", "DeskvanicPaper", "DeskvanicWeb", "DeskvanicSessionDock", "DeskvanicVoice", "DeskvanicFlow",
            ],
            path: "Tests/DeskvanicModuleTests",
            swiftSettings: commonSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)

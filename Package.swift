// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Voice",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Voice", targets: ["Voice"]),
        .executable(name: "voicectl", targets: ["voicectl"]),
    ],
    targets: [
        .target(
            name: "VoiceCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Voice",
            dependencies: ["VoiceCore"]
        ),
        .executableTarget(
            name: "voicectl",
            dependencies: ["VoiceCore"]
        ),
        .testTarget(
            name: "VoiceCoreTests",
            dependencies: ["VoiceCore"]
        ),
    ]
)

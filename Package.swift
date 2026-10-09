// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Voice",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Voice", targets: ["Voice"]),
        .executable(name: "voicectl", targets: ["voicectl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.7"),
    ],
    targets: [
        .target(
            name: "VoiceCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
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

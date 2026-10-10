// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Tack",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Tack", targets: ["Tack"]),
        .executable(name: "tackctl", targets: ["tackctl"]),
    ],
    dependencies: [
        // No traits: skips FluidAudio's NeMo text-normalization binary, which ASR does not use.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.7", traits: []),
    ],
    targets: [
        .target(
            name: "TackCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Tack",
            dependencies: ["TackCore"]
        ),
        .executableTarget(
            name: "tackctl",
            dependencies: ["TackCore"]
        ),
        .testTarget(
            name: "TackCoreTests",
            dependencies: ["TackCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)

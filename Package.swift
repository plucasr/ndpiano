// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "nordpiano",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "NordPianoCore"),
        .target(name: "NordMoog"),
        .target(
            name: "NordPianoEngine",
            dependencies: ["NordPianoCore", "NordMoog"]
        ),
        .executableTarget(
            name: "nordpiano",
            dependencies: ["NordPianoCore", "NordPianoEngine"]
        ),
        .executableTarget(
            name: "NordPianoApp",
            dependencies: ["NordPianoCore", "NordPianoEngine"]
        ),
        .testTarget(
            name: "NordPianoCoreTests",
            dependencies: ["NordPianoCore", "NordPianoEngine"]
        ),
        .testTarget(
            name: "NordMoogTests",
            dependencies: ["NordMoog"]
        ),
    ]
)

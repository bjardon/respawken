// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Respawken",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Respawken",
            path: "Sources/Respawken"
        )
    ]
)

// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "mindle",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "mindle",
            path: "Sources/mindle"
        )
    ]
)

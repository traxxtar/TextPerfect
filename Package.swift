// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "TextPerfect",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "TextPerfect",
            path: "Sources/TextPerfect"
        )
    ]
)

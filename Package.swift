// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "ScreenshotTool",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "ScreenshotTool",
            path: "Sources/ScreenshotTool"
        )
    ]
)

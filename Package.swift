// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OleDownloadManager",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OleDownloadCore", targets: ["OleDownloadCore"]),
        .library(name: "OleBrowserBridge", targets: ["OleBrowserBridge"]),
        .executable(name: "OleNativeHost", targets: ["OleNativeHost"]),
    ],
    targets: [
        // Versioned browser <-> app message protocol, framing and the Unix-socket client.
        // Kept separate so the native messaging host stays small.
        .target(name: "OleBrowserBridge"),
        // Download engine, queue, persistence, file system, settings. No UI code.
        .target(
            name: "OleDownloadCore",
            dependencies: ["OleBrowserBridge"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // Native messaging host launched by Chrome/Firefox; relays messages to the app.
        .executableTarget(name: "OleNativeHost", dependencies: ["OleBrowserBridge"]),
        .testTarget(
            name: "OleDownloadCoreTests",
            dependencies: ["OleDownloadCore", "OleBrowserBridge"]
        ),
    ]
)

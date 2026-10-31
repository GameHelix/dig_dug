// swift-tools-version: 6.4
import Foundation
import PackageDescription

// The Command Line Tools ship Swift Testing's macro plugin in a folder SwiftPM does not search
// on its own; point the compiler at it so `swift test` works without Xcode.
let testingPlugins = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let testSettings: [SwiftSetting] = FileManager.default.fileExists(atPath: testingPlugins + "/libTestingMacros.dylib")
    ? [.unsafeFlags(["-plugin-path", testingPlugins])]
    : []

let package = Package(
    name: "LessonHTTP",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "LessonHTTP", targets: ["LessonHTTP"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.104.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", exact: "1.28.0"),
    ],
    targets: [
        // The HTTP/1.1 client for command-line lesson checks; TLS comes from Network.framework.
        .target(
            name: "LessonHTTP",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
            ]
        ),
        .testTarget(
            name: "LessonHTTPTests",
            dependencies: [
                "LessonHTTP",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            swiftSettings: testSettings
        ),
    ]
)

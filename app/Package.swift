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
    name: "Gopherwood",
    platforms: [.macOS(.v27)],
    products: [
        .executable(name: "Gopherwood", targets: ["Gopherwood"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.9.0"),
        // The HTTP/1.1 client for command-line checks, on SwiftNIO (app/Packages/LessonHTTP).
        .package(path: "Packages/LessonHTTP"),
        // jq 1.8.2 with Oniguruma, compiled in (app/Packages/JQ).
        .package(path: "Packages/JQ"),
        // The code editor (TextKit 2), and SyntaxCore: the highlighting types it shares with
        // the Go lexer (app/Packages/CodeEditor).
        .package(path: "Packages/CodeEditor"),
    ],
    targets: [
        // Models and services; imports neither SwiftUI nor AppKit.
        .target(
            name: "GopherwoodKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "LessonHTTP", package: "LessonHTTP"),
                .product(name: "JQ", package: "JQ"),
                .product(name: "SyntaxCore", package: "CodeEditor"),
            ]
        ),
        // The SwiftUI app.
        .executableTarget(
            name: "Gopherwood",
            dependencies: [
                "GopherwoodKit",
                .product(name: "CodeEditor", package: "CodeEditor"),
                .product(name: "SyntaxCore", package: "CodeEditor"),
            ]
        ),
        .testTarget(
            name: "GopherwoodKitTests",
            dependencies: [
                "GopherwoodKit",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "JQ", package: "JQ"),
                .product(name: "SyntaxCore", package: "CodeEditor"),
            ],
            swiftSettings: testSettings
        ),
    ]
)

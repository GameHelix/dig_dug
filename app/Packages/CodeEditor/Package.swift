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
    name: "CodeEditor",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "SyntaxCore", targets: ["SyntaxCore"]),
        .library(name: "CodeEditor", targets: ["CodeEditor"]),
    ],
    targets: [
        // Highlighting types shared with the app's models; imports neither AppKit nor SwiftUI.
        .target(name: "SyntaxCore"),
        // The editor: an NSTextView on TextKit 2 behind a SwiftUI view, and the syntax theme.
        .target(name: "CodeEditor", dependencies: ["SyntaxCore"]),
        // `swift run CodeEditorDemo` opens a window with the editor.
        .executableTarget(name: "CodeEditorDemo", dependencies: ["CodeEditor", "SyntaxCore"]),
        .testTarget(name: "SyntaxCoreTests", dependencies: ["SyntaxCore"], swiftSettings: testSettings),
        .testTarget(name: "CodeEditorTests", dependencies: ["CodeEditor", "SyntaxCore"], swiftSettings: testSettings),
    ]
)

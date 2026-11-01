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
    name: "JQ",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "JQ", targets: ["JQ"]),
    ],
    targets: [
        // The vendored C builds as jq's own build does: warnings off, and headers included as
        // text rather than as Clang modules, so configure's macros reach the system headers.

        // Oniguruma 6.9.10, the part jq uses; written by scripts/vendor.sh.
        .target(
            name: "COniguruma",
            exclude: [
                "COPYING",
                // Tables that unicode.c includes.
                "src/unicode_egcb_data.c",
                "src/unicode_fold_data.c",
                "src/unicode_property_data.c",
                "src/unicode_wb_data.c",
            ],
            cSettings: [.unsafeFlags(["-w", "-fno-modules"])]
        ),
        // jq 1.8.2 with decNumber, the library without the command; written by scripts/vendor.sh.
        .target(
            name: "CJQ",
            dependencies: ["COniguruma"],
            exclude: ["COPYING", "src/builtin.inc"],
            cSettings: [
                // jq's own include paths: the top folder for "src/builtin.inc", vendor for decNumber.
                .headerSearchPath("."),
                .headerSearchPath("vendor"),
                // jq takes configure's defines on the command line; this header carries them.
                .unsafeFlags(["-w", "-fno-modules", "-include", "jq_config.h"]),
            ]
        ),
        .target(name: "JQ", dependencies: ["CJQ"]),
        .testTarget(name: "JQTests", dependencies: ["JQ"], swiftSettings: testSettings),
    ]
)

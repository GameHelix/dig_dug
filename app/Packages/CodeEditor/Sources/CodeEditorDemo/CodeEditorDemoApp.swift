import AppKit
import SwiftUI

/// A window with the editor beside a readme-style code block.
///
/// Options: `--appearance light|dark`, `--large` (about 5,000 lines), `--read-only`,
/// `--no-line-numbers` and `--font-size N`.
@main
struct CodeEditorDemoApp: App {
    @NSApplicationDelegateAdaptor(DemoAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Code Editor") {
            DemoView(options: DemoOptions(arguments: ProcessInfo.processInfo.arguments))
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            // Edit > Find, which the editor's find bar answers.
            TextEditingCommands()
        }
    }
}

struct DemoOptions {
    var appearance: DemoAppearance = .system
    var isLarge = false
    var isReadOnly = false
    var showsLineNumbers = true
    var fontSize: CGFloat = 13

    init(arguments: [String]) {
        var remaining = arguments.dropFirst()[...]
        while let argument = remaining.popFirst() {
            switch argument {
            case "--appearance": appearance = DemoAppearance(rawValue: remaining.popFirst() ?? "") ?? .system
            case "--large": isLarge = true
            case "--read-only": isReadOnly = true
            case "--no-line-numbers": showsLineNumbers = false
            case "--font-size": fontSize = (remaining.popFirst().flatMap(Double.init)).map { CGFloat($0) } ?? 13
            default: break
            }
        }
    }
}

final class DemoAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A bare executable starts in the background; bring it forward like an app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        NSApp.appearance = DemoOptions(arguments: ProcessInfo.processInfo.arguments).appearance.nsAppearance
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

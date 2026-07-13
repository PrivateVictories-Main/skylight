import AppKit
import SwiftUI

@main
struct SkylightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Claude Chat") { state.addAssistant(.claude) }
                    .keyboardShortcut("n", modifiers: [.command])
                Button("New ChatGPT Chat") { state.addAssistant(.chatgpt) }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                Divider()
                Button("New Terminal") { state.addTerminal() }
                    .keyboardShortcut("t", modifiers: [.command])
                Button("New Claude Code Session") { state.addTerminal(.claudeCode) }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("New Codex Session") { state.addTerminal(.codex) }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                Divider()
                Button("New Canvas") { state.selection = .canvas(state.newCanvas().id) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
    }
}

/// Running as a SwiftPM executable (no bundle), we must promote ourselves to a
/// regular, activatable app or no window appears.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Debug hook: force an appearance without touching system settings.
        switch ProcessInfo.processInfo.environment["SKYLIGHT_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }
}

import AppKit
import SwiftUI
import SkylightCore

@main
struct SkylightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        // Single-window app: a live terminal NSView cannot render in two
        // window hierarchies at once.
        Window("Skylight", id: "main") {
            ContentView()
                .environmentObject(state)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Terminal…") { state.newSheetShown = true }
                    .keyboardShortcut("t", modifiers: [.command])
                Button("New Shell Terminal") { state.launch(TerminalSpec()) }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Divider()
                Button("New Canvas") { state.selection = .canvas(state.newCanvas().id) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("Back to Canvas") { state.endFocus() }
                    .keyboardShortcut(".", modifiers: [.command])
                    .disabled(state.focusedInstance == nil)
            }
        }
    }
}

/// Running as a SwiftPM executable (no bundle), we must promote ourselves to
/// a regular, activatable app or no window appears.
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

    func applicationWillTerminate(_ notification: Notification) {
        // A debounced pan write may still be pending — flush the real state.
        MainActor.assumeIsolated {
            AppState.shared?.persist()
        }
    }
}

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
                Divider()
                // Zoom is a property of the VISIBLE canvas — with no canvas
                // shown, or one covered by focus mode, these would be silent
                // no-ops rather than commands.
                Button("Zoom In") { state.requestZoom(.zoomIn) }
                    .keyboardShortcut("+", modifiers: [.command])
                    .disabled(!state.canvasZoomAvailable)
                Button("Zoom Out") { state.requestZoom(.zoomOut) }
                    .keyboardShortcut("-", modifiers: [.command])
                    .disabled(!state.canvasZoomAvailable)
                Button("Zoom to Fit") { state.requestZoom(.fit) }
                    .keyboardShortcut("0", modifiers: [.command])
                    .disabled(!state.canvasZoomAvailable)
                Button("Actual Size") { state.requestZoom(.actual) }
                    .keyboardShortcut("1", modifiers: [.command])
                    .disabled(!state.canvasZoomAvailable)
                Divider()
                // Arrange needs everything zoom needs AND at least two tiles
                // to compose — a one-tile board is already arranged, so the
                // item goes grey rather than firing a command that returns
                // immediately.
                Button("Arrange Canvas") { state.requestArrange() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(!state.canArrange)
                Divider()
                // Granted once to Skylight, inherited by every terminal and
                // agent inside it — and, with a stable signing identity, kept
                // across rebuilds. See scripts/setup-signing.sh.
                Button("Open Full Disk Access Settings…") {
                    // Ventura renamed the pane. Try the modern id first and
                    // fall back only when the system says it could not open
                    // it — so this keeps working on both sides of that split
                    // without sniffing the OS version.
                    let modern = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")
                    let legacy = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
                    if let modern, NSWorkspace.shared.open(modern) { return }
                    if let legacy { _ = NSWorkspace.shared.open(legacy) }
                }
            }
        }
    }
}

/// Running as a SwiftPM executable (no bundle), we must promote ourselves to
/// a regular, activatable app or no window appears.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // An automated launch (screenshot runs, tests) must never steal the
        // user's focus — background-only automation as an app feature. A
        // human double-click behaves exactly as before.
        if ProcessInfo.processInfo.environment["SKYLIGHT_NO_ACTIVATE"] == nil {
            NSApp.activate(ignoringOtherApps: true)
        }
        // Debug hook: force an appearance without touching system settings.
        switch ProcessInfo.processInfo.environment["SKYLIGHT_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Deleting ONE terminal asks first; a reflexive ⌘Q was ending six
        // agents mid-task with no question at all. Same care, same copy —
        // and only when there is actually something alive to LOSE: with the
        // session keeper connected, quitting loses nothing (the sessions run
        // on and reattach next launch), so it asks nothing.
        MainActor.assumeIsolated {
            guard let state = AppState.shared, state.liveSessionCount > 0,
                  !state.sessions.sessionsSurviveQuit else {
                return .terminateNow
            }
            let live = state.liveSessionCount
            let alert = NSAlert()
            alert.messageText = "Quit Skylight?"
            alert.informativeText = live == 1
                ? "The running session will end."
                : "\(live) running sessions will end."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            // A debounced pan write may still be pending — flush the real
            // state. And a delete's kill frame may still be queued for the
            // daemon: drain it, or the next launch inherits a session whose
            // instance is gone (the orphan sweep would heal it, but only if
            // a terminal is ever opened).
            AppState.shared?.persist()
            AppState.shared?.sessions.flushDaemon()
        }
    }
}

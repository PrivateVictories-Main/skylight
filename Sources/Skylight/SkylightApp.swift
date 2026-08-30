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
            // File: the three ways something new comes to exist.
            CommandGroup(after: .newItem) {
                Button("New Terminal…") { state.newSheetShown = true }
                    .keyboardShortcut("t", modifiers: [.command])
                Button("New Shell Terminal") { state.launch(TerminalSpec()) }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Divider()
                Button("New Canvas") { state.selection = .canvas(state.newCanvas().id) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            // View: where a Mac hand reaches for zoom and navigation.
            CommandGroup(after: .sidebar) {
                Divider()
                Button("Back to Canvas") { state.endFocus() }
                    .keyboardShortcut(".", modifiers: [.command])
                    .disabled(state.focusedInstance == nil)
                Divider()
                // Zoom is a property of the VISIBLE canvas — with no canvas
                // shown, or one covered by focus mode, these would be silent
                // no-ops rather than commands. ⌘0 = Actual Size, the
                // platform's muscle memory (Safari, Preview) — and 100% is
                // this canvas's magic number.
                Button("Actual Size") { state.requestZoom(.actual) }
                    .keyboardShortcut("0", modifiers: [.command])
                    .disabled(!state.canvasZoomAvailable)
                Button("Zoom In") { state.requestZoom(.zoomIn) }
                    .keyboardShortcut("+", modifiers: [.command])
                    .disabled(!state.canvasZoomAvailable)
                Button("Zoom Out") { state.requestZoom(.zoomOut) }
                    .keyboardShortcut("-", modifiers: [.command])
                    .disabled(!state.canvasZoomAvailable)
                Button("Zoom to Fit") { state.requestZoom(.fit) }
                    .keyboardShortcut("9", modifiers: [.command])
                    .disabled(!state.canvasZoomAvailable)
                Divider()
                // Arrange needs everything zoom needs AND at least two tiles
                // to compose — a one-tile board is already arranged, so the
                // item goes grey rather than firing a command that returns
                // immediately.
                Button("Arrange Canvas") { state.requestArrange() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(!state.canArrange)
            }
            // App menu: FDA is an app-level grant, not a document action.
            CommandGroup(after: .appSettings) {
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
            // The README is the manual; the stock item opened an error dialog.
            CommandGroup(replacing: .help) {
                Button("Skylight Help") {
                    if let url = URL(string: "https://github.com/PrivateVictories-Main/skylight#readme") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        // ⌘, — the look is interchangeable (light/dark, glass/flat) from one
        // small pane. No terminal ever renders here, so the single-window
        // constraint above is untouched.
        Settings {
            SettingsView()
                // The Subscriptions tab reads live probe state.
                .environmentObject(state)
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
        // Otherwise the stored Settings choice applies (or clears to system).
        switch ProcessInfo.processInfo.environment["SKYLIGHT_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default:
            Appearance.apply(UserDefaults.standard.string(forKey: Appearance.appearanceKey))
        }
        // Debug hook, like the appearance override: lets screenshot
        // automation exercise the sheet without synthesizing clicks.
        if let mode = ProcessInfo.processInfo.environment["SKYLIGHT_OPEN_SHEET"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                AppState.shared?.debugSheetAgentMode = mode == "agent"
                AppState.shared?.newSheetShown = true
            }
        }
        // Reduce Transparency reaches INSIDE the terminals too: ghostty's
        // background-opacity is per-surface config, so the toggle re-applies
        // it to every live surface (the SwiftUI layers watch on their own).
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                AppState.shared?.sessions.refreshSurfaceConfig()
                // The theme carries opacity and blur too, and Reduce
                // Transparency outranks both — so the colour lane has to be
                // re-applied alongside the config lane, or a themed terminal
                // would keep its translucency after the system said solid.
                AppState.shared?.sessions.refreshSurfaceTheme()
            }
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

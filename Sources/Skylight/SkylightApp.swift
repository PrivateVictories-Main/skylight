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
                Button("New Terminal") { state.addTerminal() }
                    .keyboardShortcut("t", modifiers: [.command])
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
    }
}

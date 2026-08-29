import AppKit
import SwiftUI

/// The app's appearance choices, persisted in UserDefaults and applied
/// process-wide. Two knobs, deliberately: the look is interchangeable —
/// light or dark, glass or flat — without growing a preferences thicket.
enum Appearance {
    static let appearanceKey = "appearanceOverride"
    static let backgroundKey = "windowBackground"

    /// Apply a stored appearance choice to the app. "system" clears the
    /// override so the OS setting rules again — including live changes.
    @MainActor
    static func apply(_ raw: String?) {
        switch raw {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}

/// Settings (⌘,): the whole pane on one screen, no tabs. Every control
/// applies instantly — there is nothing to confirm and nothing to restart.
struct SettingsView: View {
    @AppStorage(Appearance.appearanceKey) private var appearance = "system"
    @AppStorage(Appearance.backgroundKey) private var background = "glass"

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.segmented)

            Picker("Window Background", selection: $background) {
                Text("Glass").tag("glass")
                Text("Flat").tag("flat")
            }
            .pickerStyle(.segmented)

            Text(background == "glass"
                ? "The window carries a soft blur of whatever is behind it."
                : "The window sits on a solid, standard background.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize()
        .onChange(of: appearance) { _, raw in Appearance.apply(raw) }
    }
}

import AppKit
import SwiftUI

/// The app's appearance choices, persisted in UserDefaults and applied
/// process-wide. Two knobs, deliberately: the look is interchangeable —
/// light or dark, glass or flat — without growing a preferences thicket.
enum Appearance {
    static let appearanceKey = "appearanceOverride"
    static let backgroundKey = "windowBackground"
    static let terminalOpacityKey = "terminalOpacity"

    /// The slider's floor keeps text readable over any desktop; 0 would be
    /// an invisible terminal, which no one means.
    static let terminalOpacityRange = 0.5...1.0
    static let terminalOpacityDefault = 0.92

    /// The stored terminal translucency, clamped so a hand-edited or stale
    /// default can never produce an unreadable surface — and forced solid
    /// while Reduce Transparency is on: the system setting outranks ours,
    /// exactly as Motion defers to Reduce Motion. Read fresh, like Motion.
    static var terminalOpacity: Double {
        guard !reduceTransparency else { return 1.0 }
        let stored = UserDefaults.standard.object(forKey: terminalOpacityKey) as? Double
        return min(max(stored ?? terminalOpacityDefault,
                       terminalOpacityRange.lowerBound),
                   terminalOpacityRange.upperBound)
    }

    /// The accessibility master switch over everything translucent here:
    /// window glass and terminal alike go solid while it is on.
    static var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    static let fontSizeKey = "terminalFontSize"

    /// The offered sizes. 0 is the sentinel for "ghostty's own default" —
    /// when unset, the generated config says nothing about fonts at all, so
    /// the curated engine default keeps ruling rather than being frozen to
    /// whatever number it happened to be when this shipped.
    static let fontSizes = [11, 12, 13, 14, 15, 16, 18]

    /// The stored terminal text size; 0 (or anything unoffered) = default.
    static var terminalFontSize: Int {
        let stored = UserDefaults.standard.integer(forKey: fontSizeKey)
        return fontSizes.contains(stored) ? stored : 0
    }

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
    @AppStorage(Appearance.terminalOpacityKey)
    private var terminalOpacity = Appearance.terminalOpacityDefault
    @AppStorage(Appearance.fontSizeKey) private var fontSize = 0
    @State private var reduceTransparency = Appearance.reduceTransparency

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

            // Live on every open terminal, not a promise about future ones.
            Slider(value: $terminalOpacity, in: Appearance.terminalOpacityRange) {
                Text("Terminal Background")
            } minimumValueLabel: {
                Text("Clear").font(.system(size: 11)).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("Solid").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .disabled(reduceTransparency)

            // Controls that silently do nothing are worse than none: while
            // the system setting overrides these, the pane says so.
            if reduceTransparency {
                Text("Reduce Transparency is on in System Settings, so the window and terminals stay solid.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            // Same live lane as the slider — every open terminal reflows.
            Picker("Text Size", selection: $fontSize) {
                Text("Default").tag(0)
                Divider()
                ForEach(Appearance.fontSizes, id: \.self) { size in
                    Text("\(size) pt").tag(size)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize()
        .onChange(of: appearance) { _, raw in Appearance.apply(raw) }
        .onChange(of: terminalOpacity) { _, _ in
            AppState.shared?.sessions.refreshSurfaceConfig()
        }
        .onChange(of: fontSize) { _, _ in
            AppState.shared?.sessions.refreshSurfaceConfig()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
            reduceTransparency = Appearance.reduceTransparency
        }
    }
}

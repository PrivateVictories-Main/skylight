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

    static let fontFamilyKey = "terminalFontFamily"

    /// The stored terminal font family, or nil for the engine's own. Validated
    /// on read as well as on import: a font can be uninstalled after it was
    /// chosen, and asking ghostty for a face that is not there renders in
    /// something else with nothing to explain why.
    static var terminalFontFamily: String? {
        guard let stored = UserDefaults.standard.string(forKey: fontFamilyKey),
              !stored.isEmpty, fontIsInstalled(stored) else { return nil }
        return stored
    }

    /// Is this face actually on the machine? The check a theme's font claim
    /// has to pass before it is allowed to apply.
    static func fontIsInstalled(_ family: String) -> Bool {
        !NSFontManager.shared.availableMembers(ofFontFamily: family).isNilOrEmpty
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

private extension Optional where Wrapped: Collection {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}

/// Settings (⌘,): native macOS tabs. It was one calm screen until themes
/// arrived with a searchable catalogue and an importer; two calm screens beat
/// one crowded one, and tabs are what a Mac app uses to say so.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            ThemeSettingsView()
                .tabItem { Label("Theme", systemImage: "paintpalette") }
            SubscriptionSettingsView()
                .tabItem { Label("Subscriptions", systemImage: "person.badge.key") }
        }
        .frame(width: 460)
    }
}

/// The original pane, unchanged in behavior: light/dark, glass/flat, terminal
/// translucency, text size. Every control still applies instantly.
struct GeneralSettingsView: View {
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
        .onChange(of: appearance) { _, raw in
            Appearance.apply(raw)
            // Light and dark are two different theme slots, so a manual
            // appearance flip has to re-ask which one is now in force.
            AppState.shared?.sessions.refreshSurfaceTheme()
        }
        .onChange(of: terminalOpacity) { _, _ in
            ThemeStore.shared.snapshotNoteHandEdit()
            AppState.shared?.sessions.refreshSurfaceConfig()
        }
        .onChange(of: fontSize) { _, _ in
            ThemeStore.shared.snapshotNoteHandEdit()
            AppState.shared?.sessions.refreshSurfaceConfig()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
            reduceTransparency = Appearance.reduceTransparency
        }
    }
}

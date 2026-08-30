import Foundation
import GhosttyTerminal
import SkylightCore

/// Which themes are active, and how they reach a surface.
///
/// Two slots, light and dark, because `TerminalTheme` has two and the engine
/// picks between them by effective colour scheme. Either may be nil, meaning
/// "the engine's own curated default" — which is exactly what a single-scheme
/// import leaves behind in the slot it did not fill. Forcing an inverse would
/// invent a theme nobody chose.
///
/// The names are stored, not the themes: a bundled theme is 485-entries-worth
/// of data already on disk, and keeping a copy of one in UserDefaults would be
/// a second version of it to drift. (Imported themes get their own sidecar
/// files; that arrives with the import UI.)
@MainActor
final class ThemeStore {
    static let shared = ThemeStore()

    static let lightKey = "themeLight"
    static let darkKey = "themeDark"

    private(set) var light: SkylightTheme?
    private(set) var dark: SkylightTheme?

    private init() { reload() }

    /// Re-resolve both slots from stored names. Cheap and synchronous: a name
    /// lookup against an in-memory catalogue.
    func reload() {
        light = Self.resolve(UserDefaults.standard.string(forKey: Self.lightKey))
        dark = Self.resolve(UserDefaults.standard.string(forKey: Self.darkKey))
    }

    /// Set a slot by name; nil clears it back to the engine default.
    func select(light lightName: String?, dark darkName: String?) {
        UserDefaults.standard.set(lightName, forKey: Self.lightKey)
        UserDefaults.standard.set(darkName, forKey: Self.darkKey)
        reload()
    }

    /// True when neither slot is set — the app is wearing the engine's own
    /// look and `setTheme` has nothing to say.
    var isDefault: Bool { light == nil && dark == nil }

    /// The active theme for the appearance currently on screen, or nil while
    /// both slots are empty. Chrome tinting reads this.
    func active(isDarkAppearance: Bool) -> SkylightTheme? {
        isDarkAppearance ? dark ?? light : light ?? dark
    }

    private static func resolve(_ name: String?) -> SkylightTheme? {
        guard let name, !name.isEmpty else { return nil }
        return ThemeCatalogBridge.resolve(named: name)
    }

    /// What every surface is told to wear. Reduce Transparency is threaded in
    /// here rather than read inside the bridge so the whole precedence order
    /// stays visible at one call site.
    func terminalTheme() -> TerminalTheme {
        ThemeCatalogBridge.terminalTheme(light: light, dark: dark,
                                         reduceTransparency: Appearance.reduceTransparency)
    }
}

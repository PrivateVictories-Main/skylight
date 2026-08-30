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
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    static let lightKey = "themeLight"
    static let darkKey = "themeDark"

    private(set) var light: SkylightTheme?
    private(set) var dark: SkylightTheme?

    /// Bumped whenever the active theme changes.
    ///
    /// The terminal surfaces are pushed at directly, but the app's own chrome
    /// is SwiftUI reading a static (`ThemeTint`) that no view depends on — so
    /// nothing invalidated, and the canvas, dot grid and panels kept their old
    /// tint until some unrelated state change happened to redraw them.
    /// Repainting because the Settings window activated is not repainting; it
    /// is a coincidence that usually looks like it worked.
    @Published private(set) var revision = 0

    private init() {
        reload()
        loadSnapshot()
    }

    /// Re-resolve both slots from stored names. Cheap and synchronous: a name
    /// lookup against an in-memory catalogue.
    func reload() {
        light = Self.resolve(UserDefaults.standard.string(forKey: Self.lightKey))
        dark = Self.resolve(UserDefaults.standard.string(forKey: Self.darkKey))
        revision &+= 1
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

    /// An imported theme SHADOWS a bundled one of the same name, deliberately:
    /// if someone brought over their own "Catppuccin Mocha", that is the one
    /// they meant, not the catalogue's copy of it.
    private static func resolve(_ name: String?) -> SkylightTheme? {
        guard let name, !name.isEmpty else { return nil }
        if let imported = loadImported(named: name) { return imported }
        return ThemeCatalogBridge.resolve(named: name)
    }

    // MARK: - Imported themes on disk

    private static let supportDir: URL = {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Skylight/themes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// A filename that cannot escape the themes directory, cannot be empty,
    /// and cannot be a dotfile. Theme names come from files other people
    /// wrote: "../../../etc" is a name, so is "", so is ".".
    ///
    /// Two names that differ only in punctuation DO collide here ("Solarized
    /// Dark" and "Solarized-Dark" both become "solarized-dark"), and that is
    /// accepted rather than solved with a hash: the file is meant to be
    /// findable by a human, a collision costs one overwritten import of a
    /// theme with a near-identical name, and the alternative is a directory of
    /// unreadable filenames. A digest suffix is the fix if it ever bites.
    private static func slug(_ name: String) -> String {
        let mapped = name.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : "-"
        }
        // Collapse runs and trim: "  A  B  " must not become "--a--b--".
        let collapsed = String(mapped).lowercased()
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        // An empty or all-punctuation name would write "" (the directory
        // itself) or ".json" (a hidden file the picker never shows).
        return collapsed.isEmpty ? "theme" : collapsed
    }

    private static func loadImported(named name: String) -> SkylightTheme? {
        let url = supportDir.appendingPathComponent("\(slug(name)).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SkylightTheme.self, from: data)
    }

    /// Instance-side alias so views do not reach for the type directly.
    var importedThemes: [SkylightTheme] { Self.imported }

    /// A hand edit after an import stands on its own but must not cost the
    /// ability to undo the import (see ThemeSnapshotStore).
    func snapshotNoteHandEdit() { snapshots.noteHandEdit() }

    /// Every theme imported so far, newest name order irrelevant — the picker
    /// sorts. Unreadable files are skipped rather than failing the whole list.
    static var imported: [SkylightTheme] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: supportDir, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                (try? Data(contentsOf: url)).flatMap {
                    try? JSONDecoder().decode(SkylightTheme.self, from: $0)
                }
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Persist an imported theme so it survives relaunch. Atomic, and a
    /// failure to write is not a reason to refuse the import — the theme still
    /// applies for this run.
    @discardableResult
    static func save(_ theme: SkylightTheme) -> Bool {
        guard let data = try? JSONEncoder().encode(theme) else { return false }
        let url = supportDir.appendingPathComponent("\(slug(theme.name)).json")
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    // MARK: - The revert snapshot

    private static var snapshotURL: URL {
        supportDir.appendingPathComponent("pre-import-snapshot.json")
    }

    private(set) var snapshots = ThemeSnapshotStore()

    /// Capture the world as it stands, then let the caller apply. Ryan's
    /// ratified rule is that an import WINS over everything set by hand —
    /// which is only defensible because this makes getting back one click.
    func captureSnapshot() {
        snapshots.capture(Self.currentValues())
        persistSnapshot()
    }

    /// Put every captured value back and forget the snapshot. Returns false
    /// when there was nothing to revert.
    @discardableResult
    func revert() -> Bool {
        guard let values = snapshots.revert() else { return false }
        let defaults = UserDefaults.standard
        defaults.set(values.appearance, forKey: Appearance.appearanceKey)
        defaults.set(values.windowBackground, forKey: Appearance.backgroundKey)
        if let opacity = values.terminalOpacity {
            defaults.set(opacity, forKey: Appearance.terminalOpacityKey)
        }
        defaults.set(values.terminalFontSize ?? 0, forKey: Appearance.fontSizeKey)
        defaults.set(values.fontFamily, forKey: Appearance.fontFamilyKey)
        select(light: values.lightTheme, dark: values.darkTheme)
        persistSnapshot()
        return true
    }

    var canRevert: Bool { snapshots.canRevert }

    private static func currentValues() -> ThemeSnapshot {
        let defaults = UserDefaults.standard
        return ThemeSnapshot(
            appearance: defaults.string(forKey: Appearance.appearanceKey),
            windowBackground: defaults.string(forKey: Appearance.backgroundKey),
            terminalOpacity: defaults.object(forKey: Appearance.terminalOpacityKey) as? Double,
            // object(forKey:), like the opacity above: integer(forKey:)
            // returns 0 for "never set", which is indistinguishable from the
            // 0 that MEANS "engine default" — so a revert could not tell
            // "restore the default" from "restore nothing".
            terminalFontSize: defaults.object(forKey: Appearance.fontSizeKey) as? Int,
            fontFamily: defaults.string(forKey: Appearance.fontFamilyKey),
            lightTheme: defaults.string(forKey: lightKey),
            darkTheme: defaults.string(forKey: darkKey))
    }

    private func persistSnapshot() {
        if let stored = snapshots.stored, let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: Self.snapshotURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: Self.snapshotURL)
        }
    }

    private func loadSnapshot() {
        guard let data = try? Data(contentsOf: Self.snapshotURL),
              let stored = try? JSONDecoder().decode(ThemeSnapshot.self, from: data)
        else { return }
        snapshots = ThemeSnapshotStore(snapshot: stored)
    }

    // MARK: - Applying an import

    /// The one path an imported theme takes: snapshot, persist, select, and
    /// let everything that watches appearance catch up. An import wins over
    /// hand-set values by design — the snapshot above is the way back.
    func apply(_ theme: SkylightTheme) {
        captureSnapshot()
        Self.save(theme)
        let defaults = UserDefaults.standard
        // "Applies EVERYTHING": the look the theme states reaches the app's
        // own settings, not only the terminal's colours.
        let applied = ThemeApplication.appearance(for: theme,
                                                  reduceTransparency: false)
        defaults.set(applied.isDark ? "dark" : "light", forKey: Appearance.appearanceKey)
        if theme.backgroundOpacity != nil {
            defaults.set(applied.opacity, forKey: Appearance.terminalOpacityKey)
        }
        if let size = applied.fontSize, Appearance.fontSizes.contains(Int(size)) {
            defaults.set(Int(size), forKey: Appearance.fontSizeKey)
        }
        // A font we do not have installed is not applied — the theme would
        // silently render in something else and look broken for no visible
        // reason. Honest fallback, named to the user by the import sheet.
        if let family = applied.fontFamily, Appearance.fontIsInstalled(family) {
            defaults.set(family, forKey: Appearance.fontFamilyKey)
        }
        if theme.isDarkDerived {
            select(light: UserDefaults.standard.string(forKey: Self.lightKey),
                   dark: theme.name)
        } else {
            select(light: theme.name,
                   dark: UserDefaults.standard.string(forKey: Self.darkKey))
        }
    }

    /// Fonts a theme names but the machine does not have. Surfaced by the
    /// import sheet alongside the theme's own `skipped` list.
    static func unavailableFont(in theme: SkylightTheme) -> String? {
        guard let family = theme.fontFamily,
              !Appearance.fontIsInstalled(family) else { return nil }
        return family
    }

    /// What every surface is told to wear. Reduce Transparency is threaded in
    /// here rather than read inside the bridge so the whole precedence order
    /// stays visible at one call site.
    func terminalTheme() -> TerminalTheme {
        ThemeCatalogBridge.terminalTheme(light: light, dark: dark,
                                         reduceTransparency: Appearance.reduceTransparency)
    }
}

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
/// Preferences store names; imported themes and the previous appearance live
/// together in an atomic library file. Bundled themes resolve from the catalog.
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

    /// A single transaction includes the library and the undo point. This
    /// prevents a saved theme and its snapshot from getting out of step.
    private struct Library: Codable {
        var version = 1
        var themes: [String: SkylightTheme] = [:]
        var snapshot: ThemeSnapshot?
    }

    private let defaults: UserDefaults
    private let supportDirectory: URL
    private var library: Library
    private var loadFailure: Error?
    private var libraryURL: URL {
        supportDirectory.appendingPathComponent("__skylight-theme-library-v1.json")
    }

    /// Injectable paths keep persistence tests away from the user's settings.
    init(defaults: UserDefaults = .standard,
         supportDirectory: URL = WorkspacePaths.supportDirectory
            .appendingPathComponent("themes", isDirectory: true)) {
        self.defaults = defaults
        self.supportDirectory = supportDirectory
        library = Library()
        let url = supportDirectory.appendingPathComponent("__skylight-theme-library-v1.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let decoded = try JSONDecoder().decode(Library.self, from: Data(contentsOf: url))
                guard decoded.version == 1 else {
                    throw NSError(domain: "Skylight.Theme", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "The saved theme library uses an unsupported version."])
                }
                library = decoded
            } catch {
                // A damaged library must never be replaced with an empty one
                // just because the next import happened to be writable.
                loadFailure = error
            }
        } else {
            // Read the original sidecar layout without renaming or deleting
            // any files. The first successful import writes the new library.
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: supportDirectory, includingPropertiesForKeys: nil)) ?? []
            for file in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                where file.pathExtension == "json" {
                if let data = try? Data(contentsOf: file),
                   let theme = try? JSONDecoder().decode(SkylightTheme.self, from: data) {
                    library.themes[theme.name] = theme
                }
            }
            let snapshotURL = supportDirectory.appendingPathComponent("pre-import-snapshot.json")
            if let data = try? Data(contentsOf: snapshotURL) {
                library.snapshot = try? JSONDecoder().decode(ThemeSnapshot.self, from: data)
            }
        }
        reload()
    }

    /// Re-resolve both appearance slots from the durable library and catalog.
    func reload() {
        light = resolve(defaults.string(forKey: Self.lightKey))
        dark = resolve(defaults.string(forKey: Self.darkKey))
        revision &+= 1
    }

    func select(light lightName: String?, dark darkName: String?) {
        defaults.set(lightName, forKey: Self.lightKey)
        defaults.set(darkName, forKey: Self.darkKey)
        reload()
    }

    var isDefault: Bool { light == nil && dark == nil }

    func active(isDarkAppearance: Bool) -> SkylightTheme? {
        isDarkAppearance ? dark ?? light : light ?? dark
    }

    private func resolve(_ name: String?) -> SkylightTheme? {
        guard let name, !name.isEmpty else { return nil }
        return library.themes[name] ?? ThemeCatalogBridge.resolve(named: name)
    }

    var importedThemes: [SkylightTheme] {
        library.themes.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Hand edits retain the last import's undo point.
    func snapshotNoteHandEdit() {}

    var canRevert: Bool { library.snapshot != nil }

    private func currentValues() -> ThemeSnapshot {
        ThemeSnapshot(
            appearance: defaults.string(forKey: Appearance.appearanceKey),
            windowBackground: defaults.string(forKey: Appearance.backgroundKey),
            terminalOpacity: defaults.object(forKey: Appearance.terminalOpacityKey) as? Double,
            terminalFontSize: defaults.object(forKey: Appearance.fontSizeKey) as? Int,
            fontFamily: defaults.string(forKey: Appearance.fontFamilyKey),
            lightTheme: defaults.string(forKey: Self.lightKey),
            darkTheme: defaults.string(forKey: Self.darkKey),
            lightThemeValues: light, darkThemeValues: dark)
    }

    private func persist(_ next: Library) throws {
        if let loadFailure { throw loadFailure }
        let data = try JSONEncoder().encode(next)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try data.write(to: libraryURL, options: .atomic)
        library = next
    }

    /// The library commit happens before any visible preference changes. A
    /// failed import leaves the previous appearance and undo point intact.
    func apply(_ theme: SkylightTheme) throws {
        guard !theme.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "Skylight.Theme", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "The theme needs a name before it can be saved."])
        }
        var next = library
        next.snapshot = currentValues()
        next.themes[theme.name] = theme
        try persist(next)

        let applied = ThemeApplication.appearance(for: theme, reduceTransparency: false)
        defaults.set(applied.isDark ? "dark" : "light", forKey: Appearance.appearanceKey)
        if theme.backgroundOpacity != nil {
            defaults.set(applied.opacity, forKey: Appearance.terminalOpacityKey)
        }
        if let size = applied.fontSize,
           let offered = Appearance.fontSizes.first(where: { Double($0) == size }) {
            defaults.set(offered, forKey: Appearance.fontSizeKey)
        }
        if let family = applied.fontFamily, Appearance.fontIsInstalled(family) {
            defaults.set(family, forKey: Appearance.fontFamilyKey)
        }
        if theme.isDarkDerived {
            select(light: defaults.string(forKey: Self.lightKey), dark: theme.name)
        } else {
            select(light: theme.name, dark: defaults.string(forKey: Self.darkKey))
        }
    }

    /// Restore both unset preferences and the actual previous palettes, even
    /// after a same-name reimport or app restart. Failed writes keep undo available.
    @discardableResult
    func revert() throws -> Bool {
        guard let values = library.snapshot else { return false }
        var next = library
        if let theme = values.lightThemeValues { next.themes[theme.name] = theme }
        if let theme = values.darkThemeValues { next.themes[theme.name] = theme }
        next.snapshot = nil
        try persist(next)

        defaults.set(values.appearance, forKey: Appearance.appearanceKey)
        defaults.set(values.windowBackground, forKey: Appearance.backgroundKey)
        defaults.set(values.terminalOpacity, forKey: Appearance.terminalOpacityKey)
        defaults.set(values.terminalFontSize, forKey: Appearance.fontSizeKey)
        defaults.set(values.fontFamily, forKey: Appearance.fontFamilyKey)
        select(light: values.lightTheme, dark: values.darkTheme)
        return true
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

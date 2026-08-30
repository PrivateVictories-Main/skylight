import Foundation
import GhosttyTerminal
import GhosttyTheme
import SkylightCore

/// The adapter between ghostty's bundled theme catalogue and Skylight's model,
/// in both directions.
///
/// It is deliberately thin and deliberately here rather than in SkylightCore:
/// the catalogue lives in the engine package, Core stays engine-free, and the
/// actual mapping work is `SkylightTheme.init(catalogName:...)` where it can be
/// unit-tested. What is left is plumbing.
///
/// The catalogue is worth this much wiring on its own: 485 themes already on
/// disk, so a user who has never opened another terminal still gets a real
/// choice on day one, with zero parsing involved.
enum ThemeCatalogBridge {
    /// Every bundled theme, in catalogue order.
    static var all: [SkylightTheme] {
        GhosttyThemeCatalog.allThemes.compactMap(convert)
    }

    /// Resolve a `theme = NAME` reference from an imported ghostty config.
    /// Case-insensitive, because people type "catppuccin mocha".
    static func resolve(named name: String) -> SkylightTheme? {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard let match = GhosttyThemeCatalog.allThemes.first(where: {
            $0.name.lowercased() == wanted
        }) else { return nil }
        return convert(match)
    }

    static func search(_ query: String) -> [SkylightTheme] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return all }
        return GhosttyThemeCatalog.search(query).compactMap(convert)
    }

    private static func convert(_ definition: GhosttyThemeDefinition) -> SkylightTheme? {
        SkylightTheme(catalogName: definition.name,
                      background: definition.background,
                      foreground: definition.foreground,
                      cursorColor: definition.cursorColor,
                      cursorText: definition.cursorText,
                      selectionBackground: definition.selectionBackground,
                      selectionForeground: definition.selectionForeground,
                      palette: definition.palette)
    }

    // MARK: - Into the engine

    /// A Skylight theme as the engine's own configuration. The pure half —
    /// which keys get written, the clamps, the precedence — is decided by
    /// `ThemeApplication` in SkylightCore; this only spells the result in
    /// GhosttyTerminal's vocabulary.
    ///
    /// `custom(key:value:)` is the library's documented escape hatch and takes
    /// exactly the ghostty key names ThemeApplication already emits, so the
    /// translation stays a loop rather than a second copy of the decision.
    static func terminalConfiguration(for theme: SkylightTheme,
                                      reduceTransparency: Bool) -> TerminalConfiguration {
        var configuration = TerminalConfiguration()
        for command in ThemeApplication.configCommands(for: theme,
                                                       reduceTransparency: reduceTransparency) {
            configuration = configuration.custom(command.key, command.value)
        }
        return configuration
    }

    /// Light and dark slots. A single-scheme import fills the slot matching
    /// its own luminance and leaves the other alone — forcing an inverse would
    /// invent a theme nobody chose.
    static func terminalTheme(light: SkylightTheme?, dark: SkylightTheme?,
                              reduceTransparency: Bool) -> TerminalTheme {
        TerminalTheme(
            light: light.map {
                terminalConfiguration(for: $0, reduceTransparency: reduceTransparency)
            } ?? TerminalConfiguration.alabaster,
            dark: dark.map {
                terminalConfiguration(for: $0, reduceTransparency: reduceTransparency)
            } ?? TerminalConfiguration.afterglow)
    }
}

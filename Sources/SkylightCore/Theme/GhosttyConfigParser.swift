import Foundation

/// A ghostty config, read for its LOOK.
///
/// This is the highest-fidelity importer there is, because Skylight's internal
/// theme model is ghostty's model — nothing is being translated, only read.
/// It is also the one whose fixture is the machine this was built on: if it
/// cannot read Ryan's own `~/.config/ghostty/config`, nothing below it is
/// worth trusting.
///
/// `theme = NAME` is returned as a REFERENCE rather than resolved here: the
/// bundled catalogue lives in the engine package, and SkylightCore stays free
/// of it. The caller resolves the name and merges, so the explicit colour
/// lines in a config still win over the theme it names — ghostty's own rule.
public struct ParsedGhosttyConfig: Equatable, Sendable {
    public var theme: SkylightTheme
    /// `theme = NAME`
    public var themeReference: String?
    /// `theme = light:X,dark:Y`
    public var lightThemeReference: String?
    public var darkThemeReference: String?
}

public enum GhosttyConfigParser {
    /// nil when the file says nothing about appearance at all. A config full
    /// of window sizes is not a theme, and returning a black one invented from
    /// defaults would be worse than admitting there is nothing here.
    public static func parse(_ contents: String, name: String) -> ParsedGhosttyConfig? {
        var theme = SkylightTheme(name: name, source: .ghostty,
                                  background: Color8(r: 0, g: 0, b: 0),
                                  foreground: Color8(r: 255, g: 255, b: 255))
        var sawLookKey = false
        // A ghostty config has no `name` key at all, so the filename is a
        // fallback label and never a statement — it must not win over the
        // theme the file references.
        var statedBackground = false
        var statedForeground = false
        var skipped: Set<String> = []
        var themeReference: String?
        var lightReference: String?
        var darkReference: String?
        /// An alpha channel smuggled inside `background` becomes opacity — but
        /// only if the file never states one outright.
        var alphaOpacity: Double?
        var explicitOpacity: Double?
        /// Repeated `font-family` is a FALLBACK CHAIN in ghostty; the head of
        /// it is the face the user chose, so the first one wins here even
        /// though every other key is last-wins.
        var fontFamilySet = false

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<separator]
                .trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }

            switch ThemeKeyPolicy.decide(key) {
            case .refused:
                skipped.insert(key)
                continue
            case .ignored:
                continue
            case .importable:
                break
            }

            sawLookKey = true
            switch key {
            case "background":
                // An unparseable colour is this key failing, not the file
                // ceasing to be a theme — clearing sawLookKey here used to
                // discard every OTHER look key the file had already given us.
                guard let colour = Color8(value) else {
                    skipped.insert("background (unreadable colour)")
                    continue
                }
                theme.background = colour.rgb
                alphaOpacity = colour.opacity
                statedBackground = true
            case "foreground":
                guard let colour = Color8(value) else {
                    skipped.insert("foreground (unreadable colour)")
                    continue
                }
                theme.foreground = colour.rgb
                statedForeground = true
            case "cursor-color":
                theme.cursor = Color8(value)?.rgb
            case "cursor-text":
                theme.cursorText = Color8(value)?.rgb
            case "selection-background":
                theme.selectionBackground = Color8(value)?.rgb
            case "selection-foreground":
                theme.selectionForeground = Color8(value)?.rgb
            case "bold-color":
                theme.bold = Color8(value)?.rgb
            case "palette":
                // `palette = N=#RRGGBB`
                guard let split = value.firstIndex(of: "=") else { continue }
                let index = Int(value[value.startIndex..<split]
                    .trimmingCharacters(in: .whitespaces))
                let colour = Color8(String(value[value.index(after: split)...]))
                if let index, let colour, (0...255).contains(index) {
                    theme.palette[index] = colour.rgb
                }
            case "background-opacity":
                explicitOpacity = Double(value)
            case "background-blur", "background-blur-radius":
                theme.backgroundBlur = Int(value)
            case "font-family":
                // Free text reaching a line-based config: a bare \r survives
                // this parser's \n split and would ride into the rendered
                // file as a directive of its own. Refused and named, never
                // trimmed into something nobody wrote.
                guard let safe = ThemeKeyPolicy.safeValue(value) else {
                    skipped.insert("font-family (contains a line break)")
                    continue
                }
                if !fontFamilySet {
                    theme.fontFamily = safe
                    fontFamilySet = true
                }
            case "font-size":
                theme.fontSize = Double(value)
            case "cursor-style":
                guard let safe = ThemeKeyPolicy.safeValue(value) else {
                    skipped.insert("cursor-style (contains a line break)")
                    continue
                }
                theme.cursorStyle = safe
            case "cursor-style-blink":
                theme.cursorBlink = value == "true"
            case "window-padding-x":
                theme.paddingX = Int(value)
            case "window-padding-y":
                theme.paddingY = Int(value)
            case "minimum-contrast":
                theme.minimumContrast = Double(value)
            case "theme":
                // `theme = light:X,dark:Y` or `theme = NAME`.
                // Decided by each PART's prefix, never by a substring of the
                // whole: `contains("light:")` also matches a theme genuinely
                // called "Highlight:Neon", and then neither branch sets a
                // reference and the theme silently disappears.
                let parts = value.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                let isDual = parts.contains {
                    $0.hasPrefix("light:") || $0.hasPrefix("dark:")
                }
                if isDual {
                    for piece in parts {
                        if piece.hasPrefix("light:") {
                            lightReference = String(piece.dropFirst(6))
                                .trimmingCharacters(in: .whitespaces)
                        } else if piece.hasPrefix("dark:") {
                            darkReference = String(piece.dropFirst(5))
                                .trimmingCharacters(in: .whitespaces)
                        }
                    }
                } else {
                    themeReference = value
                }
            default:
                continue
            }
        }

        let hasThemeReference = themeReference != nil
            || lightReference != nil || darkReference != nil
        // Look keys alone are not a theme. A file that sets only a font size
        // has no colours to give, and handing back the seeded black/white as
        // though it had chosen them is exactly the invention this module
        // refuses everywhere else. Colours, or a theme to resolve, or nothing.
        guard statedBackground || statedForeground || hasThemeReference else {
            return nil
        }
        _ = sawLookKey
        theme.stated = SkylightTheme.StatedFields(name: false,
                                                  background: statedBackground,
                                                  foreground: statedForeground)
        // One anchor given and the other seeded: say so, the same way the VS
        // Code importer reports a background inferred from the editor.
        if statedBackground != statedForeground {
            skipped.insert(statedBackground
                ? "foreground (not stated — using the default)"
                : "background (not stated — using the default)")
        }

        // An explicit background-opacity outranks an alpha channel: one is a
        // statement, the other a side effect of how the colour was written.
        theme.backgroundOpacity = explicitOpacity ?? alphaOpacity
        theme.skipped = skipped.sorted()
        return ParsedGhosttyConfig(theme: theme, themeReference: themeReference,
                                   lightThemeReference: lightReference,
                                   darkThemeReference: darkReference)
    }
}

import Foundation

/// Warp themes: small YAML files with a fixed, shallow shape —
/// `background`, `foreground`, `accent`, and a `terminal_colors` block of
/// `normal`/`bright` maps keyed by COLOUR NAME.
///
/// The shape is fixed enough that a scalar reader beats a YAML dependency: two
/// indent levels, `key: value`, no anchors, no flow style, no multi-line
/// scalars. Anything Warp actually ships fits.
///
/// The name→index mapping is written out deliberately. Warp names its colours
/// and ANSI numbers them, and getting that wrong swaps red and blue in every
/// program the user runs while nothing about the file looks wrong.
public enum WarpThemeParser {
    private static let ansiOrder = ["black", "red", "green", "yellow",
                                    "blue", "magenta", "cyan", "white"]

    public static func parse(_ contents: String, name: String) -> SkylightTheme? {
        var background: Color8?
        var foreground: Color8?
        var palette: [Int: Color8] = [:]
        /// Which block we are inside: nil, "normal" (0–7) or "bright" (8–15).
        var block: String?
        var inTerminalColors = false

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let separator = trimmed.firstIndex(of: ":") else { continue }

            let key = String(trimmed[trimmed.startIndex..<separator])
                .trimmingCharacters(in: .whitespaces).lowercased()
            var value = String(trimmed[trimmed.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            // Quotes come off FIRST. A colour is spelled `'#1e1e2e'` here, and
            // hunting for a trailing comment before unquoting truncates the
            // value at its own leading `#` — every colour in the file becomes
            // an empty string, and the theme silently fails to parse.
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            // Only a WHITESPACE-preceded hash starts a comment; the one that
            // opens a colour literal does not.
            if let hash = value.range(of: " #") {
                value = String(value[value.startIndex..<hash.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            }

            // Tabs count as indentation too. Measuring only spaces read every
            // tab-indented nested key as top-level, which put the colour names
            // outside the terminal_colors block and lost the whole palette.
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count

            if indent == 0 {
                inTerminalColors = key == "terminal_colors"
                block = nil
            }
            if inTerminalColors {
                if indent > 0, value.isEmpty, key == "normal" || key == "bright" {
                    block = key
                    continue
                }
                if let block, let index = ansiOrder.firstIndex(of: key),
                   let colour = Color8(value) {
                    palette[block == "bright" ? index + 8 : index] = colour.rgb
                }
                continue
            }

            switch key {
            case "background": background = Color8(value)?.rgb
            case "foreground": foreground = Color8(value)?.rgb
            default: continue   // `accent` and `details` have no terminal meaning
            }
        }

        // No background or no foreground: not a theme. Same refusal the other
        // importers make rather than inventing the missing half.
        guard let background, let foreground else { return nil }
        return SkylightTheme(name: name, source: .warp,
                             background: background, foreground: foreground,
                             palette: palette)
    }
}

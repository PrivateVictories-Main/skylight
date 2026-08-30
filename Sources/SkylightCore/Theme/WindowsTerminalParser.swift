import Foundation

/// Windows Terminal `settings.json` — the one importer that returns MANY
/// themes, because that file holds a `schemes` array and people bring the
/// whole thing over from a PC rather than a single scheme.
///
/// Two things this format gets to teach every caller:
///
/// 1. **It calls magenta "purple".** The name→index map is written out for
///    the same reason Warp's is: getting it wrong recolours every program the
///    user runs and nothing about the file looks wrong.
/// 2. **Opacity lives on the PROFILE, not the scheme.** They are different
///    objects with no link between them beyond `colorScheme`. Joining the
///    default profile's opacity and font onto every scheme is a judgement
///    call — a useful one, since it is what the person was actually looking
///    at — so it is applied AND named in `skipped`, never smuggled.
public enum WindowsTerminalParser {
    /// ANSI order, in Windows Terminal's spelling.
    private static let names = ["black", "red", "green", "yellow",
                                 "blue", "purple", "cyan", "white"]

    public static func parse(_ data: Data, name: String) -> [SkylightTheme] {
        guard let root = JSONC.object(from: data),
              let schemes = root["schemes"] as? [[String: Any]]
        else { return [] }

        // The default profile's look, joined onto every scheme below.
        let defaults = (root["profiles"] as? [String: Any])
            .flatMap { $0["defaults"] as? [String: Any] }
        var joined: [String] = []
        var opacity: Double?
        if let raw = defaults?["opacity"] as? Double {
            // Newer settings write 0–100, older ones 0–1. "1" is opaque under
            // both readings, so the split point is safe either way.
            opacity = raw > 1 ? raw / 100 : raw
            joined.append("opacity \(raw) joined from the default profile")
        }
        let font = defaults?["font"] as? [String: Any]
        let fontSize = font?["size"] as? Double
        // THE reachable value-injection vector: face is a JSON string, and
        // JSON carries line breaks inside strings without complaint. A face
        // holding one would render as `font-family = Consolas` followed by
        // whatever directive came after the break.
        var fontFamily: String?
        if let face = font?["face"] as? String {
            fontFamily = ThemeKeyPolicy.safeValue(face)
            if fontFamily == nil {
                joined.append("font face (contains a line break)")
            }
        }
        if fontFamily != nil || fontSize != nil {
            joined.append("font joined from the default profile")
        }

        return schemes.compactMap { scheme in
            func colour(_ key: String) -> Color8? {
                (scheme[key] as? String).flatMap(Color8.init)
            }
            // A scheme missing either anchor colour is half a scheme; drop it
            // rather than inventing the other half.
            guard let background = colour("background"),
                  let foreground = colour("foreground") else { return nil }

            var theme = SkylightTheme(
                name: (scheme["name"] as? String) ?? name,
                source: .windowsTerminal,
                background: background.rgb,
                foreground: foreground.rgb,
                cursor: colour("cursorColor")?.rgb,
                selectionBackground: colour("selectionBackground")?.rgb)

            for (index, ansi) in names.enumerated() {
                if let normal = colour(ansi) { theme.palette[index] = normal.rgb }
                let bright = "bright" + ansi.prefix(1).uppercased() + ansi.dropFirst()
                if let brightColour = colour(bright) {
                    theme.palette[index + 8] = brightColour.rgb
                }
            }

            theme.backgroundOpacity = opacity ?? background.opacity
            theme.fontFamily = fontFamily
            theme.fontSize = fontSize
            theme.skipped = joined.sorted()
            return theme
        }
    }
}

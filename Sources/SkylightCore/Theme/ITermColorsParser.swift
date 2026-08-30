import Foundation

/// iTerm2 `.itermcolors` — an Apple XML plist where every colour is a dict of
/// 0–1 `Red/Green/Blue Component` reals.
///
/// The one trap worth naming: modern files carry a `Color Space` of `sRGB` or
/// `P3`, and a P3 file read as sRGB is *visibly* wrong — saturated colours
/// shift. We do not attempt a conversion we cannot verify against iTerm2's own
/// rendering, and we do not silently mis-import either: the numbers land (they
/// are real) and the colour space is reported so the person can see what they
/// got. Half-knowledge stated out loud beats a confident wrong answer.
///
/// Uses `PropertyListSerialization` — Foundation, no dependency.
public enum ITermColorsParser {
    public static func parse(_ data: Data, name: String) -> SkylightTheme? {
        guard !data.isEmpty,
              let root = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any]
        else { return nil }

        var colourSpaces: Set<String> = []
        func colour(_ key: String) -> (Color8, Double?)? {
            guard let dict = root[key] as? [String: Any],
                  let r = dict["Red Component"] as? Double,
                  let g = dict["Green Component"] as? Double,
                  let b = dict["Blue Component"] as? Double
            else { return nil }
            if let space = dict["Color Space"] as? String { colourSpaces.insert(space) }
            let alpha = dict["Alpha Component"] as? Double
            return (Color8(floatComponents: (r, g, b)), alpha)
        }

        // A scheme with neither a background nor a foreground is not a theme;
        // half of one is worse than an honest refusal.
        guard let background = colour("Background Color"),
              let foreground = colour("Foreground Color")
        else { return nil }

        var theme = SkylightTheme(name: name, source: .iterm2,
                                  background: background.0.rgb,
                                  foreground: foreground.0.rgb)
        // Written out rather than driven from a keypath table: a static table
        // of WritableKeyPaths is not Sendable under Swift 6, and five lines of
        // plain assignment are clearer than the dance required to keep one.
        theme.cursor = colour("Cursor Color")?.0.rgb
        theme.cursorText = colour("Cursor Text Color")?.0.rgb
        theme.selectionBackground = colour("Selection Color")?.0.rgb
        theme.selectionForeground = colour("Selected Text Color")?.0.rgb
        theme.bold = colour("Bold Color")?.0.rgb
        for index in 0...255 {
            if let ansi = colour("Ansi \(index) Color") {
                theme.palette[index] = ansi.0.rgb
            }
        }
        // The background's alpha is the window transparency the user chose.
        if let alpha = background.1, alpha < 1 {
            theme.backgroundOpacity = alpha
        }
        // Reported, not guessed at: a P3 file's numbers are honest, their
        // INTERPRETATION is what we cannot promise.
        for space in colourSpaces.sorted() where space.lowercased() != "srgb" {
            theme.skipped.append("Color Space \(space) (read as sRGB — colours may shift)")
        }
        return theme
    }
}

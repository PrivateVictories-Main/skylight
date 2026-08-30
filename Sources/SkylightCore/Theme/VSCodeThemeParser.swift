import Foundation

/// VS Code colour themes and `settings.json` alike: a `colors` map (or
/// `workbench.colorCustomizations`) with dotted keys.
///
/// The honest-import problem this format poses: **most themes never set
/// `terminal.background`.** The integrated terminal simply inherits the
/// editor, so a strict reader would refuse three quarters of the themes people
/// actually want to bring over. Falling back to `editor.background` is right —
/// doing it silently is not, so the inference is recorded and shown.
public enum VSCodeThemeParser {
    /// VS Code names its ANSI colours; the order here is the ANSI order.
    private static let ansiNames = ["Black", "Red", "Green", "Yellow",
                                     "Blue", "Magenta", "Cyan", "White"]

    public static func parse(_ data: Data, name: String) -> SkylightTheme? {
        guard let root = JSONC.object(from: data) else { return nil }
        let colours = (root["colors"] as? [String: Any])
            ?? (root["workbench.colorCustomizations"] as? [String: Any])
            ?? root
        func colour(_ key: String) -> Color8? {
            (colours[key] as? String).flatMap(Color8.init)
        }

        var inferred: [String] = []
        var background = colour("terminal.background")
        if background == nil, let editor = colour("editor.background") {
            background = editor
            inferred.append("background inferred from editor.background")
        }
        var foreground = colour("terminal.foreground")
        if foreground == nil, let editor = colour("editor.foreground") {
            foreground = editor
            inferred.append("foreground inferred from editor.foreground")
        }
        guard let background, let foreground else { return nil }

        var theme = SkylightTheme(
            name: (root["name"] as? String) ?? name,
            source: .vscode,
            background: background.rgb,
            foreground: foreground.rgb,
            // terminalCursor.foreground is the caret; .background is the glyph
            // showing THROUGH it, which is ghostty's cursor-text.
            cursor: colour("terminalCursor.foreground")?.rgb,
            cursorText: colour("terminalCursor.background")?.rgb,
            selectionBackground: colour("terminal.selectionBackground")?.rgb,
            selectionForeground: colour("terminal.selectionForeground")?.rgb)

        for (offset, ansi) in ansiNames.enumerated() {
            if let normal = colour("terminal.ansi\(ansi)") {
                theme.palette[offset] = normal.rgb
            }
            if let bright = colour("terminal.ansiBright\(ansi)") {
                theme.palette[offset + 8] = bright.rgb
            }
        }

        // #RRGGBBAA is legal here and common — the alpha is transparency.
        theme.backgroundOpacity = background.opacity.flatMap { $0 < 1 ? $0 : nil }
        theme.skipped = inferred.sorted()
        return theme
    }
}

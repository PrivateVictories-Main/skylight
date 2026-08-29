import Foundation

/// Splitting an arguments string the way a shell reader expects.
public enum Arguments {
    /// Whitespace-separated words, with quoting: `"…"` and `'…'` group, a
    /// backslash escapes the next character (and, inside double quotes, only
    /// `"` and `\` — matching POSIX). A plain `split(separator: " ")` made an
    /// argument containing a space unexpressible: `--dir "/My Tool"` arrived
    /// as three mangled words.
    ///
    /// An unterminated quote keeps everything after it as one literal word —
    /// a half-typed line should degrade to something visible, never vanish.
    public static func split(_ input: String) -> [String] {
        var words: [String] = []
        var current = ""
        var started = false
        var quote: Character?
        var escaped = false
        for ch in input {
            if escaped {
                if quote == "\"", ch != "\"", ch != "\\" { current.append("\\") }
                current.append(ch)
                escaped = false
                continue
            }
            switch ch {
            case "\\" where quote != "'":
                escaped = true
                started = true
            case "'", "\"":
                if quote == ch { quote = nil }
                else if quote == nil { quote = ch; started = true }
                else { current.append(ch) }
            case _ where ch.isWhitespace && quote == nil:
                if started { words.append(current); current = ""; started = false }
            default:
                current.append(ch)
                started = true
            }
        }
        // Trailing backslash: literal, same fail-toward-visible rule as an
        // unterminated quote.
        if escaped { current.append("\\"); started = true }
        if started { words.append(current) }
        return words
    }
}

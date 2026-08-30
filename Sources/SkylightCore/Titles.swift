import Foundation

/// Naming a terminal after the first thing you asked it to do.
public enum Titles {
    /// Below this a prompt names nothing — and a retreat to the last word
    /// boundary never leaves less than this behind.
    private static let minimumLength = 8

    /// A sidebar-worthy name from a first prompt: whitespace collapsed,
    /// word-boundary cut near `limit` characters. nil when the prompt is too
    /// thin to name anything (short, or a slash-command — `/init` describes
    /// the tool, not the work).
    public static func derived(fromPrompt prompt: String, limit: Int = 40) -> String? {
        let collapsed = prompt
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count >= minimumLength, !collapsed.hasPrefix("/") else { return nil }
        guard collapsed.count > limit else { return collapsed }

        let cut = collapsed.index(collapsed.startIndex, offsetBy: limit)
        var head = collapsed[..<cut]
        // A cut that lands inside a word reads as a truncation bug: retreat to
        // the last boundary, unless that would leave too little to name.
        if collapsed[cut] != " ",
           let lastSpace = head.lastIndex(of: " "),
           head.distance(from: head.startIndex, to: lastSpace) >= minimumLength {
            head = head[..<lastSpace]
        }
        while head.hasSuffix(" ") { head = head.dropLast() }
        return head.isEmpty ? nil : String(head)
    }

    // MARK: - Paste sanitizing

    /// Arrow keys, F-keys and friends arrive as characters in this Private Use
    /// range; none of them belong in a name.
    private static let functionKeyScalars: ClosedRange<UInt32> = 0xF700...0xF8FF

    /// A scalar belongs in a name unless it is a control character or a
    /// function-key scalar. The single definition of that rule — typed text
    /// and pasted text differ only in what they allow ON TOP of this, and
    /// nothing may be admitted that this rejects.
    public static func isNameSafe(_ scalar: Unicode.Scalar) -> Bool {
        !CharacterSet.controlCharacters.contains(scalar)
            && !functionKeyScalars.contains(scalar.value)
    }

    /// Pasted text with complete ANSI escape sequences removed whole, and then
    /// every remaining control and function-key scalar dropped. Newlines and
    /// tabs survive, because they are legitimate in a multi-line prompt and
    /// `derived(fromPrompt:)` collapses them to spaces anyway.
    ///
    /// The two passes are both necessary. Dropping the ESC scalar alone leaves
    /// the rest of the sequence behind as ordinary printable text, which is how
    /// a pasted line of colored build output used to name a terminal
    /// "[1;31mBuild failed[0m". Stripping sequences alone would leave bare
    /// control bytes — a stray BEL, a raw \u{01} — that never appear inside a
    /// sequence at all.
    public static func sanitizedPaste(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var kept = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            if let end = escapeSequenceEnd(scalars, from: i) {
                i = end                     // a complete sequence: gone, whole
                continue
            }
            let scalar = scalars[i]
            if scalar == "\n" || scalar == "\t" || isNameSafe(scalar) {
                kept.append(scalar)
            }
            i += 1
        }
        return String(kept)
    }

    /// The index just past a COMPLETE escape sequence starting at `start`, or
    /// nil when there is not one there.
    ///
    /// Incomplete sequences deliberately return nil: a truncated copy ending
    /// mid-escape is not evidence enough to eat every character after it, and
    /// the scalar filter still drops its ESC. Only the two forms that actually
    /// turn up in copied terminal output are recognized — CSI (colors, cursor
    /// moves, erases) and OSC (window and tab titles).
    private static func escapeSequenceEnd(_ s: [Unicode.Scalar], from start: Int) -> Int? {
        guard s[start].value == 0x1B, start + 1 < s.count else { return nil }
        switch s[start + 1] {
        case "[":
            // CSI: parameter bytes, then intermediates, then one final byte.
            var i = start + 2
            while i < s.count, (0x30...0x3F).contains(s[i].value) { i += 1 }
            while i < s.count, (0x20...0x2F).contains(s[i].value) { i += 1 }
            guard i < s.count, (0x40...0x7E).contains(s[i].value) else { return nil }
            return i + 1
        case "]":
            // OSC: a payload of any length, ended by BEL or by ST (ESC \).
            var i = start + 2
            while i < s.count {
                if s[i].value == 0x07 { return i + 1 }
                if s[i].value == 0x1B, i + 1 < s.count, s[i + 1] == "\\" { return i + 2 }
                i += 1
            }
            return nil
        default:
            return nil
        }
    }
}

public extension Titles {
    /// A working directory, shortened to fit a tile header without lying
    /// about where you are.
    ///
    /// Two rules earn their keep. The tilde is only applied at a real path
    /// BOUNDARY — `/Users/ryan_smith` merely starts with `/Users/ryan_s` and
    /// belongs to somebody else. And truncation always keeps the LAST
    /// component, because that is the part that answers "where am I"; losing
    /// it to a middle ellipsis leaves a header that is decorative.
    ///
    /// nil for a path that is not one.
    static func abbreviatedPath(_ path: String, home: String,
                                maxLength: Int) -> String? {
        var path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        // A trailing slash would leave an empty last component.
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }

        var display = path
        if path == home {
            display = "~"
        } else if !home.isEmpty, path.hasPrefix(home + "/") {
            display = "~" + path.dropFirst(home.count)
        }
        guard display.count > maxLength else { return display }

        // Keep the tail whole; drop whole components off the front.
        var components = display.split(separator: "/", omittingEmptySubsequences: false)
        guard let last = components.last, !last.isEmpty else { return display }
        // A single component that alone exceeds the budget cannot be split
        // without inventing a name — show it whole rather than mangled.
        guard components.count > 1, last.count < maxLength else { return String(last) }

        while components.count > 2 {
            components.removeFirst(components.first?.isEmpty == true ? 2 : 1)
            let candidate = "…/" + components.joined(separator: "/")
            if candidate.count <= maxLength { return candidate }
            if components.count <= 1 { break }
        }
        return "…/" + String(last)
    }
}

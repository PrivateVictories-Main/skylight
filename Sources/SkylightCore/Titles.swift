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
}

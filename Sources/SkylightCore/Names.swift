import Foundation

/// Numbering a family of names. Terminals and canvases count the same way —
/// one rule, so the two can never drift into different habits.
public enum Names {
    /// "Terminal", "Terminal 2", … — always one past the HIGHEST existing
    /// suffix rather than one past the count, so deleting "Terminal 2" out of
    /// the middle never hands its number to a newcomer while "Terminal 3" is
    /// still on screen.
    ///
    /// Only the exact base and `base + " " + digits` count as members of the
    /// series. A renamed sibling ("Terminal beta") is somebody's own name that
    /// happens to start the same way, and is ignored.
    public static func numbered(base: String, among names: [String]) -> String {
        var highest = 0
        for name in names {
            if name == base {
                highest = max(highest, 1)
            } else if name.hasPrefix(base + " "),
                      let n = Int(name.dropFirst(base.count + 1)) {
                highest = max(highest, n)
            }
        }
        return highest == 0 ? base : "\(base) \(highest + 1)"
    }
}

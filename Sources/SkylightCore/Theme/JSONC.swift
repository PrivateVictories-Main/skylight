import Foundation

/// JSON with comments and trailing commas — what VS Code and Windows Terminal
/// actually write, and what `JSONSerialization` flatly refuses.
///
/// The stripper is STRING-AWARE, which is the entire difficulty. Every colour
/// in these files is `"#1e1e2e"` and plenty of values are URLs, so a naive
/// pass that hunts for `//` or `#` eats the data it was meant to preserve.
/// This walks the text once, tracking whether it is inside a string literal
/// and honouring backslash escapes, and only treats a delimiter as a delimiter
/// when it is outside one.
enum JSONC {
    /// Returns plain JSON, safe to hand to `JSONSerialization`.
    static func stripped(_ text: String) -> String {
        var output = String()
        output.reserveCapacity(text.count)
        var inString = false
        var escaped = false
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]

            if inString {
                output.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index = text.index(after: index)
                continue
            }

            if character == "\"" {
                inString = true
                output.append(character)
                index = text.index(after: index)
                continue
            }

            // Comments, only out here where they are actually comments.
            if character == "/", text.index(after: index) < text.endIndex {
                let next = text[text.index(after: index)]
                if next == "/" {
                    while index < text.endIndex, text[index] != "\n" {
                        index = text.index(after: index)
                    }
                    continue
                }
                if next == "*" {
                    index = text.index(index, offsetBy: 2)
                    while index < text.endIndex {
                        if text[index] == "*", text.index(after: index) < text.endIndex,
                           text[text.index(after: index)] == "/" {
                            index = text.index(index, offsetBy: 2)
                            break
                        }
                        index = text.index(after: index)
                    }
                    continue
                }
            }

            output.append(character)
            index = text.index(after: index)
        }

        return removingTrailingCommas(output)
    }

    /// A comma followed only by whitespace and a closing brace/bracket. Same
    /// string-awareness rule: a comma inside `"a, b"` is data.
    ///
    /// One pass, building the output — the previous version collected indices
    /// and then called `remove(at:)` for each, which shifts the tail of the
    /// array every time and turns a file with many trailing commas quadratic.
    /// A pending comma is simply held until we know what follows it.
    private static func removingTrailingCommas(_ text: String) -> String {
        var output = String()
        output.reserveCapacity(text.count)
        var inString = false
        var escaped = false
        /// A comma seen outside a string, plus the whitespace after it, held
        /// until the next non-space character decides its fate.
        var pending: String?

        for character in text {
            if inString {
                output.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }

            if var held = pending {
                if character.isWhitespace {
                    held.append(character)
                    pending = held
                    continue
                }
                // Dropped when it closed nothing but the container.
                if character != "}", character != "]" {
                    output.append(held)
                }
                pending = nil
            }

            if character == "," {
                pending = ","
                continue
            }
            if character == "\"" { inString = true }
            output.append(character)
        }

        if let held = pending { output.append(held) }
        return output
    }

    /// Parse a JSONC document into a dictionary, or nil if it is not one.
    static func object(from data: Data) -> [String: Any]? {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let cleaned = Data(stripped(text).utf8)
        return (try? JSONSerialization.jsonObject(with: cleaned)) as? [String: Any]
    }
}

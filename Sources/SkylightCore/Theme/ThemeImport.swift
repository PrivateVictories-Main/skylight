import Foundation

public enum ThemeImportError: Error, Equatable, Sendable {
    /// Nothing here looks like any format we read.
    case unrecognizedFormat
    /// No bytes at all.
    case empty
    /// A format we DID recognise that yielded nothing usable. Deliberately a
    /// different answer from `unrecognizedFormat`: "I could not read this" and
    /// "I read it and there was no theme in it" send a person to different
    /// places.
    case malformed(String)
}

/// The one door every theme file comes through.
///
/// Detection is by extension FIRST and content second, because the extension
/// is a hint and the bytes are the truth. The case that forces this: Windows
/// Terminal and VS Code both write `settings.json`, and only the presence of a
/// `schemes` array tells them apart. A file someone saved as `mytheme.txt` is
/// still a ghostty config, and it should still work.
///
/// A file may yield MANY themes (a Windows Terminal schemes array), which is
/// why the result is an array and the UI offers a choice.
public enum ThemeImport {
    public static func parse(data: Data,
                             filename: String) -> Result<[SkylightTheme], ThemeImportError> {
        guard !data.isEmpty else { return .failure(.empty) }
        let name = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension.lowercased()
        let text = String(data: data, encoding: .utf8)

        // 1. The extension, where it is unambiguous.
        switch ext {
        case "itermcolors":
            return finish(ITermColorsParser.parse(data, name: name).map { [$0] } ?? [])
        case "yml", "yaml":
            return finish(text.flatMap { WarpThemeParser.parse($0, name: name) }
                .map { [$0] } ?? [])
        default:
            break
        }

        // 2. JSON — the ambiguous case. Only the CONTENT can decide.
        if ext == "json" || looksLikeJSON(text) {
            if let root = JSONC.object(from: data) {
                if root["schemes"] != nil {
                    return finish(WindowsTerminalParser.parse(data, name: name))
                }
                return finish(VSCodeThemeParser.parse(data, name: name).map { [$0] } ?? [])
            }
        }

        // 3. A plist without the extension.
        if looksLikePlist(text), let theme = ITermColorsParser.parse(data, name: name) {
            return .success([theme])
        }

        // 4. Ghostty's `key = value` — the last resort, and the one that
        //    rescues a config saved under any name at all.
        if let text, let parsed = GhosttyConfigParser.parse(text, name: name) {
            return .success([parsed.theme])
        }

        return .failure(.unrecognizedFormat)
    }

    /// A recognised format that produced nothing is malformed, not unreadable.
    private static func finish(
        _ themes: [SkylightTheme]) -> Result<[SkylightTheme], ThemeImportError> {
        themes.isEmpty ? .failure(.malformed("no themes in file")) : .success(themes)
    }

    private static func looksLikeJSON(_ text: String?) -> Bool {
        guard let first = text?.trimmingCharacters(in: .whitespacesAndNewlines).first
        else { return false }
        return first == "{" || first == "["
    }

    private static func looksLikePlist(_ text: String?) -> Bool {
        guard let text else { return false }
        return text.contains("<plist") || text.hasPrefix("bplist")
    }
}

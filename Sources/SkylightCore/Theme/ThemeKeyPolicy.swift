import Foundation

/// What an importer is allowed to do with a key it finds in someone's config.
///
/// **A config file is not a trusted script.** Ghostty, kitty and wezterm
/// configs can all carry `command`, `keybind`, `include` and environment
/// directives — Ryan's own ghostty config launches tmux on every window. If a
/// theme import could carry those across, then "import this pretty theme
/// someone posted" would mean "run whatever they put in it".
///
/// So: **theme import reads look, never behaviour.** The importable set is an
/// allowlist of colour, typography, opacity and padding keys. Anything that
/// can name a program or a file to read is refused BY NAME, and the name is
/// shown to the user — a silent drop is indistinguishable from a parser that
/// never looked.
public enum ThemeKeyPolicy {
    public enum Decision: Equatable, Sendable {
        /// A look key: take it.
        case importable
        /// A behaviour key: never take it, and tell the user we saw it.
        case refused
        /// Neither — a key this importer has no opinion about. Noise, not a
        /// threat, so it must not clutter the refused list.
        case ignored
    }

    /// The allowlist. Every key here is spelled in at least one supported
    /// format; the parsers normalize their own dialects onto these names.
    public static let importableKeys: Set<String> = [
        // colours
        "background", "foreground", "cursor-color", "cursor-text",
        "selection-background", "selection-foreground", "bold-color",
        "palette", "minimum-contrast",
        // background treatment
        "background-opacity", "background-blur", "background-blur-radius",
        // typography
        "font-family", "font-size",
        // cursor + spacing
        "cursor-style", "cursor-style-blink", "window-padding-x",
        "window-padding-y",
        // the one indirection we follow: a named theme resolved against the
        // bundled catalogue. It names a THEME, never a file to execute.
        "theme",
    ]

    /// The refusal list: anything that names a program, a file to read, or the
    /// environment a program runs in.
    public static let refusedKeys: Set<String> = [
        "command", "initial-command", "startup-command", "exec",
        "keybind", "bind", "key",
        "env", "environment", "shell-integration", "shell-integration-features",
        "include", "globinclude", "include-file", "config-file", "source",
        "working-directory", "wait-after-command",
    ]

    public static func decide(_ rawKey: String) -> Decision {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if refusedKeys.contains(key) { return .refused }
        if importableKeys.contains(key) { return .importable }
        // `palette = 3=#aabbcc` and `color12` style keys arrive already
        // normalized by their parsers, so anything left is genuinely unknown.
        return .ignored
    }
}

import Foundation

/// The appearance values an applied theme resolves to, for the parts of the
/// app that are not a terminal surface — window chrome, light/dark, the
/// translucency slider's effective value.
public struct AppliedAppearance: Equatable, Sendable {
    public var isDark: Bool
    public var opacity: Double
    public var fontFamily: String?
    public var fontSize: Double?

    public init(isDark: Bool, opacity: Double,
                fontFamily: String? = nil, fontSize: Double? = nil) {
        self.isDark = isDark
        self.opacity = opacity
        self.fontFamily = fontFamily
        self.fontSize = fontSize
    }
}

/// Turning a theme into engine configuration — kept PURE, and kept out of the
/// engine's type system on purpose.
///
/// This emits `(key, value)` pairs rather than a `TerminalConfiguration`,
/// because SkylightCore has no business importing GhosttyTerminal: the app
/// target turns these pairs into builder calls. The cost is one small
/// translation in the app; the gain is that the whole of the apply decision —
/// clamps, precedence, which keys get written at all — is unit-testable
/// without a window or a surface.
public enum ThemeApplication {
    public struct ConfigCommand: Equatable, Sendable {
        public let key: String
        public let value: String

        public init(_ key: String, _ value: String) {
            self.key = key
            self.value = value
        }
    }

    /// The readability floor. Below this the terminal is a rumour; the same
    /// bound the Settings slider has always enforced.
    public static let opacityRange = 0.5...1.0
    /// What a theme that says nothing about transparency gets. Readability
    /// beats effect (design spec Addendum A1).
    public static let defaultOpacity = 0.92

    /// Ordered deliberately: colours, then palette ascending, then treatment,
    /// then typography, then cursor and spacing. A stable order keeps the
    /// rendered config diffable instead of reshuffling on every apply.
    ///
    /// A nil field emits NO key. That is the whole discipline: we write what
    /// the theme actually said, so the engine's own curated default keeps
    /// ruling everywhere it did not.
    public static func configCommands(for theme: SkylightTheme,
                                      reduceTransparency: Bool) -> [ConfigCommand] {
        var commands: [ConfigCommand] = []
        /// EVERY value crosses this gate, not only the free-text ones.
        /// Colours and numbers cannot carry a line break today, but a guard
        /// that covers all of them cannot be forgotten by whoever adds the
        /// next field — and the sidecar in Application Support is decoded
        /// straight into this model without a parser ever seeing it, so this
        /// boundary is the only complete defence there is.
        func emit(_ key: String, _ value: String) {
            guard let safe = ThemeKeyPolicy.safeValue(value) else { return }
            commands.append(ConfigCommand(key, safe))
        }
        emit("background", theme.background.hex)
        emit("foreground", theme.foreground.hex)
        func colour(_ key: String, _ value: Color8?) {
            if let value { emit(key, value.hex) }
        }
        colour("cursor-color", theme.cursor)
        colour("cursor-text", theme.cursorText)
        colour("selection-background", theme.selectionBackground)
        colour("selection-foreground", theme.selectionForeground)
        colour("bold-color", theme.bold)
        for index in theme.palette.keys.sorted() {
            emit("palette", "\(index)=\(theme.palette[index]!.hex)")
        }
        if let contrast = theme.minimumContrast {
            emit("minimum-contrast", trimmed(contrast))
        }

        emit("background-opacity",
             trimmed(opacity(for: theme, reduceTransparency: reduceTransparency)))
        // Blur is a translucency effect: with Reduce Transparency on it has
        // nothing to blur, and asking for it anyway would be the accessibility
        // setting being overridden by the back door.
        if let blur = theme.backgroundBlur, !reduceTransparency {
            emit("background-blur", "\(blur)")
        }

        if let family = theme.fontFamily { emit("font-family", family) }
        if let size = theme.fontSize { emit("font-size", trimmed(size)) }
        if let style = theme.cursorStyle { emit("cursor-style", style) }
        if let blink = theme.cursorBlink {
            emit("cursor-style-blink", blink ? "true" : "false")
        }
        if let x = theme.paddingX { emit("window-padding-x", "\(x)") }
        if let y = theme.paddingY { emit("window-padding-y", "\(y)") }
        return commands
    }

    public static func appearance(for theme: SkylightTheme,
                                  reduceTransparency: Bool) -> AppliedAppearance {
        AppliedAppearance(isDark: theme.isDarkDerived,
                          opacity: opacity(for: theme,
                                           reduceTransparency: reduceTransparency),
                          fontFamily: theme.fontFamily,
                          fontSize: theme.fontSize)
    }

    /// The app's own surfaces, tinted from the theme instead of from system
    /// colours. Without this an import recolours the TEXT and leaves the app
    /// around it wearing macOS grey — which reads as a terminal pasted into
    /// somebody else's window rather than one app.
    public struct ChromeTones: Equatable, Sendable {
        /// Sits under the (translucent) terminal surface.
        public let panelBacking: Color8
        /// The canvas plane behind the tiles.
        public let canvasBackdrop: Color8
        /// Tile headers and bars.
        public let header: Color8
        /// Hairline borders.
        public let hairline: Color8
        /// The endless-canvas dot field.
        public let dotGrid: Color8
    }

    /// Derived by stepping AWAY from the background — lighter on a dark theme,
    /// darker on a light one. A fixed offset in one direction works for half
    /// the themes in the catalogue and disappears for the other half, and a
    /// hairline you cannot see is the whole glass look gone.
    public static func chromeTones(for theme: SkylightTheme) -> ChromeTones {
        let background = theme.background
        // Which way is "away". Mid-grey backgrounds are the ambiguous case;
        // going darker there keeps chrome reading as recessed.
        let towardLight = background.luminance < 128

        func stepped(_ amount: Double) -> Color8 {
            let delta = towardLight ? amount : -amount
            func channel(_ value: UInt8) -> UInt8 {
                UInt8(min(255, max(0, Double(value) + delta)).rounded())
            }
            return Color8(r: channel(background.r),
                          g: channel(background.g),
                          b: channel(background.b))
        }

        // The panel backing IS the terminal background: it sits directly under
        // a translucent surface, and any drift reads as a dirty smear instead
        // of depth.
        return ChromeTones(
            panelBacking: background,
            canvasBackdrop: stepped(10),
            header: stepped(18),
            // The hairline has to clear the contrast floor on pure black and
            // pure white alike — 32 is the smallest step that does on both.
            hairline: stepped(32),
            // Texture, not content: pulled toward the foreground far enough to
            // be seen, never far enough to compete with text sitting on it.
            dotGrid: mixed(background, theme.foreground, amount: 0.28))
    }

    /// A linear blend, used only for the dot grid — the one tone that wants to
    /// belong to the foreground rather than step away from the background.
    private static func mixed(_ a: Color8, _ b: Color8, amount: Double) -> Color8 {
        func channel(_ x: UInt8, _ y: UInt8) -> UInt8 {
            UInt8((Double(x) + (Double(y) - Double(x)) * amount).rounded())
        }
        return Color8(r: channel(a.r, b.r), g: channel(a.g, b.g), b: channel(a.b, b.b))
    }

    /// One clamp, one precedence rule, one place. Reduce Transparency outranks
    /// the theme outright — the system setting is the top of the order, and an
    /// import is not allowed to reach over it.
    private static func opacity(for theme: SkylightTheme,
                                reduceTransparency: Bool) -> Double {
        guard !reduceTransparency else { return 1.0 }
        let stored = theme.backgroundOpacity ?? defaultOpacity
        return min(max(stored, opacityRange.lowerBound), opacityRange.upperBound)
    }

    /// A number a config file should carry: no exponent, no long float tail,
    /// and no trailing ".0" lost — ghostty parses "1.0" and "0.5" happily and
    /// "0.9800000000000001" is just noise in a rendered config.
    private static func trimmed(_ value: Double) -> String {
        let rounded = (value * 1000).rounded() / 1000
        if rounded == rounded.rounded(), abs(rounded) < 1e9 {
            return String(format: "%.1f", rounded)
        }
        return String(rounded)
    }
}

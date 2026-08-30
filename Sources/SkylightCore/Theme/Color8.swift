import Foundation

/// An 8-bit-per-channel colour with optional alpha — the one currency every
/// theme importer trades in.
///
/// Terminal configs spell colours a dozen ways (`#RGB`, `#RRGGBB`,
/// `#RRGGBBAA`, bare hex, `0x`-prefixed, `rgb()`, `rgba()`, X11 names, and
/// iTerm2's 0–1 float triples). Every one of them lands here, so this is the
/// single place a parsing bug can live — and the single place tests can kill
/// it for the whole space rather than a handful of samples.
///
/// Alpha is KEPT. A terminal's transparency is part of the look someone is
/// importing; dropping it silently is how a theme arrives wrong. It is folded
/// out into `background-opacity` at apply time, because ghostty's colour keys
/// take `#RRGGBB` and nothing else.
public struct Color8: Codable, Equatable, Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8?

    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8? = nil) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// The colour without its alpha — what a comparison against a plain
    /// literal should be made against.
    public var rgb: Color8 { Color8(r: r, g: g, b: b) }

    /// `#RRGGBB`, lowercase, alpha deliberately absent (see the type's note).
    public var hex: String {
        String(format: "#%02x%02x%02x", Int(r), Int(g), Int(b))
    }

    /// Alpha as a 0–1 opacity, or nil when the literal carried none.
    public var opacity: Double? {
        a.map { Double($0) / 255 }
    }

    /// Perceived brightness (ITU-R BT.601), 0–255. Used to decide whether an
    /// imported single-scheme theme belongs in the light slot or the dark one.
    public var luminance: Double {
        0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)
    }

    // MARK: - Parsing

    /// Every literal form real configs use. nil means "not a colour" — never
    /// a guess, and never a silent black: an invented colour is the same
    /// failure class as an invented autonomy flag.
    public init?(_ literal: String) {
        let trimmed = literal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let functional = Self.parseFunctional(trimmed) {
            self = functional
            return
        }
        if let named = Self.named(trimmed) {
            self = named
            return
        }

        var body = trimmed
        if body.hasPrefix("#") {
            body.removeFirst()
        } else if body.lowercased().hasPrefix("0x") {
            body.removeFirst(2)
        }
        // `Character.isHexDigit` is TRUE for fullwidth forms (Ｆ, U+FF26),
        // Arabic-Indic digits, and other non-ASCII hex digits;
        // `UInt8(_:radix:)` returns nil for every one of them. Gating on the
        // first and converting with the second left a force-unwrap sitting in
        // the gap — a crash reachable from any format, and the Theme tab
        // auto-parses discovered configs, so a single poisoned file made ⌘,
        // the trigger.
        //
        // ASCII, explicitly. `hexDigitValue` removes the crash but is
        // Unicode-aware, so it would happily read "#ＦＦ００ＡＡ" as a colour —
        // and a hex literal is ASCII by definition in every format here.
        // Accepting homoglyphs would mean two spellings of one colour and a
        // file that looks wrong but parses.
        //
        // One authority for both questions, which is the actual fix: whether a
        // character is a hex digit and what it is worth are now decided by the
        // same function, so they cannot disagree and there is no gap left for
        // a force-unwrap to sit in.
        let nibbles = body.compactMap { character -> Int? in
            guard character.isASCII, let value = character.hexDigitValue else {
                return nil
            }
            return value
        }
        guard nibbles.count == body.count else { return nil }

        switch nibbles.count {
        case 3, 4:
            // #RGB / #RGBA — each nibble doubles (the CSS rule).
            let expanded = nibbles.map { UInt8($0) << 4 | UInt8($0) }
            self.init(r: expanded[0], g: expanded[1], b: expanded[2],
                      a: expanded.count == 4 ? expanded[3] : nil)
        case 6, 8:
            let bytes = stride(from: 0, to: nibbles.count, by: 2).map {
                UInt8(nibbles[$0]) << 4 | UInt8(nibbles[$0 + 1])
            }
            self.init(r: bytes[0], g: bytes[1], b: bytes[2],
                      a: bytes.count == 4 ? bytes[3] : nil)
        default:
            return nil
        }
    }

    /// `rgb(r,g,b)` and `rgba(r,g,b,a)`. Channels are 0–255 integers; alpha is
    /// a 0–1 fraction (CSS) or a 0–255 integer, whichever the file used.
    private static func parseFunctional(_ text: String) -> Color8? {
        let lower = text.lowercased()
        let isRGBA = lower.hasPrefix("rgba(")
        guard isRGBA || lower.hasPrefix("rgb("), lower.hasSuffix(")") else { return nil }
        let inner = lower.dropFirst(isRGBA ? 5 : 4).dropLast()
        let parts = inner.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == (isRGBA ? 4 : 3) else { return nil }
        var channels: [UInt8] = []
        for part in parts.prefix(3) {
            guard let value = Int(part), (0...255).contains(value) else { return nil }
            channels.append(UInt8(value))
        }
        var alpha: UInt8?
        if isRGBA {
            guard let raw = Double(parts[3]) else { return nil }
            // 0–1 fraction or 0–255 integer: "1" is ambiguous and means opaque
            // under both readings, so the split point is safe either way.
            let scaled = raw <= 1 ? raw * 255 : raw
            guard scaled >= 0, scaled <= 255 else { return nil }
            alpha = UInt8(scaled.rounded())
        }
        return Color8(r: channels[0], g: channels[1], b: channels[2], a: alpha)
    }

    /// The colour names that actually appear in kitty/alacritty/wezterm
    /// configs. Deliberately small: a name we do not know returns nil rather
    /// than a plausible-looking wrong colour.
    ///
    /// `none` is kitty's "no colour" and must read as absence, not black.
    public static func named(_ name: String) -> Color8? {
        switch name.lowercased() {
        case "black": Color8(r: 0, g: 0, b: 0)
        case "white": Color8(r: 255, g: 255, b: 255)
        case "red": Color8(r: 255, g: 0, b: 0)
        case "green": Color8(r: 0, g: 128, b: 0)
        case "lime": Color8(r: 0, g: 255, b: 0)
        case "blue": Color8(r: 0, g: 0, b: 255)
        case "yellow": Color8(r: 255, g: 255, b: 0)
        case "cyan", "aqua": Color8(r: 0, g: 255, b: 255)
        case "magenta", "fuchsia": Color8(r: 255, g: 0, b: 255)
        case "gray", "grey": Color8(r: 128, g: 128, b: 128)
        case "silver": Color8(r: 192, g: 192, b: 192)
        case "maroon": Color8(r: 128, g: 0, b: 0)
        case "olive": Color8(r: 128, g: 128, b: 0)
        case "navy": Color8(r: 0, g: 0, b: 128)
        case "teal": Color8(r: 0, g: 128, b: 128)
        case "purple": Color8(r: 128, g: 0, b: 128)
        case "orange": Color8(r: 255, g: 165, b: 0)
        default: nil
        }
    }

    /// iTerm2's storage: three (or four) 0–1 floats. Out-of-range values are
    /// clamped and NaN reads as 0 — a malformed plist must not wrap a channel
    /// around into a colour nobody chose.
    public init(floatComponents: (Double, Double, Double), alpha: Double? = nil) {
        func byte(_ value: Double) -> UInt8 {
            guard value.isFinite else { return 0 }
            return UInt8((min(1, max(0, value)) * 255).rounded())
        }
        self.init(r: byte(floatComponents.0),
                  g: byte(floatComponents.1),
                  b: byte(floatComponents.2),
                  a: alpha.map(byte))
    }
}

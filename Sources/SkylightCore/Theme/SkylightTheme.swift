import Foundation

/// Where a theme came from. Kept on the theme itself because an import is
/// allowed to be PARTIAL, and a human deciding whether to keep it wants to
/// know which format's limits they are looking at.
public enum ThemeSource: String, Codable, Equatable, Hashable, Sendable {
    case bundled            // ghostty's own catalogue, shipped with the engine
    case ghostty
    case iterm2
    case warp
    case vscode
    case windowsTerminal
    case kitty
    case alacritty
    case wezterm
}

/// Skylight's internal theme model — deliberately shaped like ghostty's own
/// `GhosttyThemeDefinition`, plus the fields that make an import apply
/// EVERYTHING rather than just the sixteen ANSI colours.
///
/// Every field past `foreground` is optional for one reason: we import what
/// the source actually said and nothing else. A missing cursor colour stays
/// missing, so the engine's own default keeps ruling — inventing one is how a
/// theme arrives subtly wrong and nobody can say why.
public struct SkylightTheme: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var source: ThemeSource

    public var background: Color8
    public var foreground: Color8
    public var cursor: Color8?
    public var cursorText: Color8?
    public var selectionBackground: Color8?
    public var selectionForeground: Color8?
    public var bold: Color8?
    /// 0...15 in practice; 16...255 accepted because kitty and ghostty both
    /// allow the extended range and there is no reason to throw it away.
    public var palette: [Int: Color8]

    // The "applies EVERYTHING" half.
    public var backgroundOpacity: Double?
    public var backgroundBlur: Int?
    public var fontFamily: String?
    public var fontSize: Double?
    public var cursorStyle: String?
    public var cursorBlink: Bool?
    public var paddingX: Int?
    public var paddingY: Int?
    public var minimumContrast: Double?

    /// Keys the file DID contain and this import deliberately did not take —
    /// refused behaviour keys, unparseable constructs, formats we can only
    /// read part of. Surfaced to the user: a partial import is honest, a
    /// silent one is not.
    public var skipped: [String]

    public init(name: String, source: ThemeSource,
                background: Color8, foreground: Color8,
                cursor: Color8? = nil, cursorText: Color8? = nil,
                selectionBackground: Color8? = nil, selectionForeground: Color8? = nil,
                bold: Color8? = nil, palette: [Int: Color8] = [:],
                backgroundOpacity: Double? = nil, backgroundBlur: Int? = nil,
                fontFamily: String? = nil, fontSize: Double? = nil,
                cursorStyle: String? = nil, cursorBlink: Bool? = nil,
                paddingX: Int? = nil, paddingY: Int? = nil,
                minimumContrast: Double? = nil,
                skipped: [String] = []) {
        self.name = name
        self.source = source
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.cursorText = cursorText
        self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground
        self.bold = bold
        self.palette = palette
        self.backgroundOpacity = backgroundOpacity
        self.backgroundBlur = backgroundBlur
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.cursorStyle = cursorStyle
        self.cursorBlink = cursorBlink
        self.paddingX = paddingX
        self.paddingY = paddingY
        self.minimumContrast = minimumContrast
        self.skipped = skipped
    }

    /// Which appearance slot this theme belongs in when a source only gives
    /// one scheme. Luminance, not a guess at the name — "Solarized" is both.
    public var isDarkDerived: Bool { background.luminance < 128 }

    /// Later keys win, per key — ghostty's own config composition rule, which
    /// is exactly what `theme = NAME` followed by explicit colour lines means.
    /// A field the overlay never mentions survives from the base; a palette is
    /// merged per INDEX rather than replaced wholesale, so overriding colour 1
    /// does not silently erase the other fifteen.
    public func merging(_ overlay: SkylightTheme) -> SkylightTheme {
        var result = self
        result.name = overlay.name.isEmpty ? name : overlay.name
        result.source = overlay.source
        result.background = overlay.background
        result.foreground = overlay.foreground
        result.cursor = overlay.cursor ?? cursor
        result.cursorText = overlay.cursorText ?? cursorText
        result.selectionBackground = overlay.selectionBackground ?? selectionBackground
        result.selectionForeground = overlay.selectionForeground ?? selectionForeground
        result.bold = overlay.bold ?? bold
        result.palette = palette.merging(overlay.palette) { _, new in new }
        result.backgroundOpacity = overlay.backgroundOpacity ?? backgroundOpacity
        result.backgroundBlur = overlay.backgroundBlur ?? backgroundBlur
        result.fontFamily = overlay.fontFamily ?? fontFamily
        result.fontSize = overlay.fontSize ?? fontSize
        result.cursorStyle = overlay.cursorStyle ?? cursorStyle
        result.cursorBlink = overlay.cursorBlink ?? cursorBlink
        result.paddingX = overlay.paddingX ?? paddingX
        result.paddingY = overlay.paddingY ?? paddingY
        result.minimumContrast = overlay.minimumContrast ?? minimumContrast
        // Deduped and sorted: this list is read by a human, and the same key
        // refused twice is one fact, not two.
        result.skipped = Array(Set(skipped + overlay.skipped)).sorted()
        return result
    }
}

// Hashable with a dictionary member: synthesized conformance handles it, but
// the palette's key order must not leak into equality — Dictionary already
// guarantees that.

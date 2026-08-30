import AppKit
import SwiftUI
import SkylightCore

/// The app's chrome, tinted from the active theme — or the system colours when
/// no theme is set.
///
/// This is what makes an import feel like it applied EVERYTHING. Recolouring
/// only the terminal text leaves the window, the canvas plane, the tile
/// headers and the hairlines wearing macOS grey, and the result reads as a
/// terminal pasted into someone else's app rather than one piece of glass.
///
/// The tone MATH lives in SkylightCore (`ThemeApplication.chromeTones`) where
/// it is tested against contrast floors on pure black and pure white. This is
/// only the lookup and the SwiftUI spelling.
@MainActor
enum ThemeTint {
    /// The active theme for the appearance currently on screen, or nil when
    /// the app is wearing the engine's own look.
    private static var tones: ThemeApplication.ChromeTones? {
        guard let theme = ThemeStore.shared.active(isDarkAppearance: isDarkAppearance)
        else { return nil }
        return ThemeApplication.chromeTones(for: theme)
    }

    /// What the window is actually rendering as right now — the stored
    /// override if there is one, otherwise whatever the OS is doing. Read
    /// fresh, like Appearance.reduceTransparency, so a live system toggle is
    /// honoured without a relaunch.
    static var isDarkAppearance: Bool {
        switch UserDefaults.standard.string(forKey: Appearance.appearanceKey) {
        case "dark": return true
        case "light": return false
        default:
            return NSApp?.effectiveAppearance
                .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }

    private static func color(_ tone: Color8?) -> Color? {
        tone.map { Color(nsColor: NSColor(srgbRed: Double($0.r) / 255,
                                          green: Double($0.g) / 255,
                                          blue: Double($0.b) / 255,
                                          alpha: 1)) }
    }

    /// Under the terminal surface. Falls back to the system text background,
    /// which is what this has always been.
    static var panelBacking: Color {
        color(tones?.panelBacking) ?? Color(nsColor: .textBackgroundColor)
    }

    /// The canvas plane behind the tiles.
    static var canvasBackdrop: Color {
        color(tones?.canvasBackdrop) ?? Color(nsColor: .windowBackgroundColor)
    }

    /// Hairline borders. The opacity stays where the design put it; only the
    /// hue is the theme's business.
    static func hairline(opacity: Double) -> Color {
        (color(tones?.hairline) ?? Color.primary).opacity(opacity)
    }

    /// The endless-canvas dot field.
    static var dotGrid: Color {
        color(tones?.dotGrid) ?? Color.secondary.opacity(0.18)
    }

    /// Tile headers and bars keep the system material when untimed — the
    /// blur is worth more than a flat fill — and take a theme tint over it
    /// when there is one to take.
    static var header: Color? { color(tones?.header) }
}

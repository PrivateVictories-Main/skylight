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
    /// The tones for a given theme, or nil for the engine's own look.
    ///
    /// Takes the theme as an ARGUMENT rather than reading the store. The
    /// view-facing accessors live on `ThemeStore` itself (see the extension at
    /// the bottom of this file), so a view cannot read a tint without holding
    /// the observed object that invalidates it — the dependency is enforced by
    /// the compiler instead of by remembering.
    static func tones(for theme: SkylightTheme?) -> ThemeApplication.ChromeTones? {
        theme.map(ThemeApplication.chromeTones(for:))
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

    static func color(_ tone: Color8?) -> Color? {
        tone.map { Color(nsColor: NSColor(srgbRed: Double($0.r) / 255,
                                          green: Double($0.g) / 255,
                                          blue: Double($0.b) / 255,
                                          alpha: 1)) }
    }
}

/// The view-facing tints, deliberately INSTANCE members on the observable
/// store rather than statics on `ThemeTint`.
///
/// They were statics. A view read `ThemeTint.dotGrid` and separately held an
/// `@ObservedObject` that its body never mentioned — the invalidation worked
/// (SwiftUI subscribes to `objectWillChange` regardless), but the property
/// read as dead code. The next person to tidy an unused property away would
/// have silently restored the stale-chrome bug, and nothing would have failed
/// except the pixels.
///
/// Reading a tint now REQUIRES the store instance, so deleting the observed
/// property is a compile error rather than a regression nobody notices.
/// `revision` is touched in each one so the dependency survives even a future
/// refactor that caches the tones.
@MainActor
extension ThemeStore {
    private var currentTones: ThemeApplication.ChromeTones? {
        _ = revision   // load-bearing: see the note above
        return ThemeTint.tones(for: active(isDarkAppearance: ThemeTint.isDarkAppearance))
    }

    /// Under the terminal surface. Falls back to the system text background,
    /// which is what this has always been.
    var panelBacking: Color {
        ThemeTint.color(currentTones?.panelBacking)
            ?? Color(nsColor: .textBackgroundColor)
    }

    /// The canvas plane behind the tiles.
    var canvasBackdrop: Color {
        ThemeTint.color(currentTones?.canvasBackdrop)
            ?? Color(nsColor: .windowBackgroundColor)
    }

    /// Hairline borders. The opacity stays where the design put it; only the
    /// hue is the theme's business.
    func hairline(opacity: Double) -> Color {
        (ThemeTint.color(currentTones?.hairline) ?? Color.primary).opacity(opacity)
    }

    /// The endless-canvas dot field.
    var dotGrid: Color {
        ThemeTint.color(currentTones?.dotGrid) ?? Color.secondary.opacity(0.18)
    }

    /// Tile headers and bars keep the system material when untinted — the blur
    /// is worth more than a flat fill — and take a theme tint over it when
    /// there is one to take.
    var headerTint: Color? { ThemeTint.color(currentTones?.header) }
}

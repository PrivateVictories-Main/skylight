import AppKit
import SwiftUI

/// The app's motion voice, with Reduce Motion respected: springs normally,
/// near-instant fades when the user asked the system for less movement.
///
/// These are computed on purpose. A `static let` would freeze whatever the
/// setting was the first time anything animated and keep using it for the rest
/// of the launch; read fresh, toggling Reduce Motion in System Settings applies
/// to the very next animation.
enum Motion {
    /// Objects settling into place — tiles, grips, resize commits.
    static var settle: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.35, dampingFraction: 0.8)
    }

    /// The camera moving — zoom, fit, reveal, and the focus transition.
    static var viewport: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.35, dampingFraction: 0.85)
    }

    /// Button press feedback — the one bounce Reduce Motion users still see
    /// least of.
    static var press: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .easeOut(duration: 0.08)
            : .spring(response: 0.28, dampingFraction: 0.55)
    }

    /// A selection thumb gliding between options.
    static var slide: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .easeOut(duration: 0.1)
            : .spring(response: 0.32, dampingFraction: 0.78)
    }

    /// A section expanding or collapsing in place (the New sheet's tiers).
    static var disclose: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .easeOut(duration: 0.1)
            : .spring(response: 0.3, dampingFraction: 0.85)
    }
}

/// Springy press feedback for buttons — the subtle scale-and-settle that makes
/// taps feel physical. Used app-wide for a consistent, satisfying response.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.92
    var hoverable = true

    func makeBody(configuration: Configuration) -> some View {
        PressableBody(configuration: configuration, scale: scale, hoverable: hoverable)
    }

    private struct PressableBody: View {
        let configuration: Configuration
        let scale: CGFloat
        let hoverable: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? scale : (hovering && hoverable ? 1.06 : 1))
                .opacity(configuration.isPressed ? 0.85 : 1)
                .animation(Motion.press, value: configuration.isPressed)
                .animation(.easeOut(duration: 0.14), value: hovering)
                .onHover { hovering = $0 }
                .contentShape(Rectangle())
        }
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
    static func pressable(scale: CGFloat) -> PressableStyle { PressableStyle(scale: scale) }
}

/// A soft hover-highlight background for list-like rows.
struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat = 8
    var active = false
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(active
                        ? Color.accentColor.opacity(0.16)
                        : hovering ? Color.primary.opacity(0.06) : .clear)
            )
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.15), value: active)
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverHighlight(cornerRadius: CGFloat = 8, active: Bool = false) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius, active: active))
    }
}

/// Segmented capsule with a sliding thumb — the ChatGPT-app mode-switcher
/// feel: the selection pill glides between options with a spring.
struct SlidingSegments<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                Button {
                    withAnimation(Motion.slide) {
                        selection = value
                    }
                } label: {
                    Text(label)
                        .font(.system(size: 12, weight: selection == value ? .semibold : .regular))
                        .foregroundStyle(selection == value ? Color.primary : Color.secondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 4.5)
                        .background {
                            if selection == value {
                                Capsule()
                                    .fill(.background)
                                    .shadow(color: .black.opacity(0.12), radius: 2.5, y: 1)
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.055)))
    }
}

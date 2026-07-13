import SwiftUI

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
                .animation(.spring(response: 0.28, dampingFraction: 0.55), value: configuration.isPressed)
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
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
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

/// A draggable, snapping stop-slider — drag or tap between discrete levels
/// (reasoning efforts). The thumb glides with a spring, ticks light up as the
/// fill passes them, and the active label follows the selection.
struct StopSlider: View {
    let options: [String]
    @Binding var selection: String

    private var selectedIndex: Int {
        options.firstIndex(of: selection) ?? 0
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let count = max(options.count, 2)
            let step = width / CGFloat(count - 1)
            let x = CGFloat(selectedIndex) * step

            ZStack(alignment: .leading) {
                // Track + progress fill.
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 6)
                Capsule()
                    .fill(Color.accentColor.opacity(0.75))
                    .frame(width: max(x, 6), height: 6)

                // Tick dots.
                ForEach(options.indices, id: \.self) { index in
                    Circle()
                        .fill(index <= selectedIndex ? Color.accentColor : Color.primary.opacity(0.18))
                        .frame(width: 4.5, height: 4.5)
                        .position(x: CGFloat(index) * step, y: geo.size.height / 2)
                }

                // Thumb.
                Circle()
                    .fill(.background)
                    .frame(width: 20, height: 20)
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.08)))
                    .position(x: x, y: geo.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let index = Int((value.location.x / step).rounded())
                        let clamped = min(max(index, 0), options.count - 1)
                        if options[clamped] != selection {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) {
                                selection = options[clamped]
                            }
                        }
                    }
            )
        }
        .frame(height: 26)
        .padding(.horizontal, 10)
    }
}

extension Color {
    /// Hex string ("#RRGGBB") → Color.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .alphanumerics.inverted)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt64(s, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

import AppKit
import SwiftUI
import SkylightCore

/// Exact vector brand marks — transparent, infinitely crisp, 1:1 with the
/// official logos. Rendered from SVG path data so they scale perfectly and
/// tint cleanly for light/dark.
enum BrandMark {
    /// Claude Code's own mark (Simple Icons `claudecode`, viewBox 24×24) —
    /// the CLI's mark, not the Claude sunburst.
    static let claudeCodePath = "M21 10.5h3v3h-3v3h-1.5v3H18v-3h-1.5v3H15v-3H9v3H7.5v-3H6v3H4.5v-3H3v-3H0v-3h3v-6h18Zm-15 0h1.5v-3H6Zm10.5 0H18v-3h-1.5z"

    /// OpenAI's official blossom mark (canonical, viewBox 24×24).
    static let openAIPath = "M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511 4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.2599 24a6.0557 6.0557 0 0 0 5.7718-4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729zm-9.022 12.6081a4.4755 4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0 .3927-.6813v-6.7369l2.02 1.1686a.071.071 0 0 1 .038.052v5.5826a4.504 4.504 0 0 1-4.4945 4.4944zm-9.6607-4.1254a4.4708 4.4708 0 0 1-.5346-3.0137l.1419.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.8428-3.3685v2.3324a.0804.0804 0 0 1-.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1408-1.6464zM2.3408 7.8956a4.485 4.485 0 0 1 2.3655-1.9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543-2.0201 1.1685a.0757.0757 0 0 1-.071 0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7.872zm16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757 0 0 1 .071 0l4.8303 2.7913a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.407-.667zm2.0107-3.0231l-.142-.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L9.409 9.2297V6.8974a.0662.0662 0 0 1 .0284-.0615l4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66zM8.3065 12.863l-2.0201-1.1638a.0804.0804 0 0 1-.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3757-3.4537l-.142.0805L8.704 5.459a.7948.7948 0 0 0-.3927.6813zm1.0976-2.3654l2.602-1.4998 2.6069 1.4998v2.9994l-2.5974 1.4997-2.6067-1.4997Z"

    /// Google Gemini's official spark mark (Simple Icons, viewBox 24×24).
    static let geminiPath = "M11.04 19.32Q12 21.51 12 24q0-2.49.93-4.68.96-2.19 2.58-3.81t3.81-2.55Q21.51 12 24 12q-2.49 0-4.68-.93a12.3 12.3 0 0 1-3.81-2.58 12.3 12.3 0 0 1-2.58-3.81Q12 2.49 12 0q0 2.49-.96 4.68-.93 2.19-2.55 3.81a12.3 12.3 0 0 1-3.81 2.58Q2.49 12 0 12q2.49 0 4.68.96 2.19.93 3.81 2.55t2.55 3.81"

    /// GitHub Copilot's official mark (Simple Icons `githubcopilot`, viewBox 24×24).
    static let copilotPath = "M23.922 16.997C23.061 18.492 18.063 22.02 12 22.02 5.937 22.02.939 18.492.078 16.997A.641.641 0 0 1 0 16.741v-2.869a.883.883 0 0 1 .053-.22c.372-.935 1.347-2.292 2.605-2.656.167-.429.414-1.055.644-1.517a10.098 10.098 0 0 1-.052-1.086c0-1.331.282-2.499 1.132-3.368.397-.406.89-.717 1.474-.952C7.255 2.937 9.248 1.98 11.978 1.98c2.731 0 4.767.957 6.166 2.093.584.235 1.077.546 1.474.952.85.869 1.132 2.037 1.132 3.368 0 .368-.014.733-.052 1.086.23.462.477 1.088.644 1.517 1.258.364 2.233 1.721 2.605 2.656a.841.841 0 0 1 .053.22v2.869a.641.641 0 0 1-.078.256Zm-11.75-5.992h-.344a4.359 4.359 0 0 1-.355.508c-.77.947-1.918 1.492-3.508 1.492-1.725 0-2.989-.359-3.782-1.259a2.137 2.137 0 0 1-.085-.104L4 11.746v6.585c1.435.779 4.514 2.179 8 2.179 3.486 0 6.565-1.4 8-2.179v-6.585l-.098-.104s-.033.045-.085.104c-.793.9-2.057 1.259-3.782 1.259-1.59 0-2.738-.545-3.508-1.492a4.359 4.359 0 0 1-.355-.508Zm2.328 3.25c.549 0 1 .451 1 1v2c0 .549-.451 1-1 1-.549 0-1-.451-1-1v-2c0-.549.451-1 1-1Zm-5 0c.549 0 1 .451 1 1v2c0 .549-.451 1-1 1-.549 0-1-.451-1-1v-2c0-.549.451-1 1-1Zm3.313-6.185c.136 1.057.403 1.913.878 2.497.442.544 1.134.938 2.344.938 1.573 0 2.292-.337 2.657-.751.384-.435.558-1.15.558-2.361 0-1.14-.243-1.847-.705-2.319-.477-.488-1.319-.862-2.824-1.025-1.487-.161-2.192.138-2.533.529-.269.307-.437.808-.438 1.578v.021c0 .265.021.562.063.893Zm-1.626 0c.042-.331.063-.628.063-.894v-.02c-.001-.77-.169-1.271-.438-1.578-.341-.391-1.046-.69-2.533-.529-1.505.163-2.347.537-2.824 1.025-.462.472-.705 1.179-.705 2.319 0 1.211.175 1.926.558 2.361.365.414 1.084.751 2.657.751 1.21 0 1.902-.394 2.344-.938.475-.584.742-1.44.878-2.497Z"

    /// Cursor's official mark (Simple Icons `cursor`, viewBox 24×24).
    static let cursorPath = "M11.503.131 1.891 5.678a.84.84 0 0 0-.42.726v11.188c0 .3.162.575.42.724l9.609 5.55a1 1 0 0 0 .998 0l9.61-5.55a.84.84 0 0 0 .42-.724V6.404a.84.84 0 0 0-.42-.726L12.497.131a1.01 1.01 0 0 0-.996 0M2.657 6.338h18.55c.263 0 .43.287.297.515L12.23 22.918c-.062.107-.229.064-.229-.06V12.335a.59.59 0 0 0-.295-.51l-9.11-5.257c-.109-.063-.064-.23.061-.23"

    /// Qwen's official mark (Simple Icons `qwen`, viewBox 24×24).
    static let qwenPath = "M23.919 14.545 20.817 9.17l1.47-2.544a.56.56 0 0 0 0-.566l-1.633-2.83a.57.57 0 0 0-.49-.283h-6.207L12.487.402a.57.57 0 0 0-.49-.284H8.732a.56.56 0 0 0-.49.284L5.139 5.775h-2.94a.56.56 0 0 0-.49.284L.077 8.887a.56.56 0 0 0 0 .567L3.18 14.83l-1.47 2.545a.56.56 0 0 0 0 .566l1.634 2.83a.57.57 0 0 0 .49.283h6.205l1.47 2.545a.57.57 0 0 0 .49.284h3.266a.57.57 0 0 0 .49-.284l3.104-5.375h2.94a.57.57 0 0 0 .49-.283l1.634-2.828a.55.55 0 0 0-.004-.568M8.733.686l1.634 2.828-1.634 2.828H21.8L20.164 9.17H7.425L5.63 6.06Zm1.306 19.801-6.205-.002 1.634-2.83h3.265L2.201 6.344h3.267q3.182 5.517 6.367 11.032zm10.124-5.66L18.53 12l-6.532 11.315-1.634-2.83c2.129-3.673 4.25-7.351 6.373-11.028h3.592l3.102 5.374z"

    /// Amp ships under Sourcegraph, so it wears the Sourcegraph mark
    /// (Simple Icons `sourcegraph` — the `amp` slug is Google AMP, viewBox 24×24).
    static let ampPath = "M17.897 3.84a2.38 2.38 0 1 1 3.09 3.623l-3.525 3.006-2.59-.919-.967-.342-1.625-.576 1.312-1.12.78-.665 3.525-3.007zm-8.27 13.313.78-.665 1.312-1.12-1.624-.575-.967-.344-2.59-.918-3.525 3.007a2.38 2.38 0 1 0 3.09 3.622l3.525-3.007zM8.724 7.37l2.592.92 2.09-1.784-.84-4.556a2.38 2.38 0 1 0-4.683.865l.841 4.555zm6.554 9.262-2.592-.92-2.091 1.784.842 4.557a2.38 2.38 0 0 0 4.682-.866l-.841-4.555zm8.186-.564a2.38 2.38 0 0 0-1.449-3.04l-4.365-1.55-.967-.342-1.625-.576-.966-.343-2.59-.92-.967-.342-1.624-.576-.967-.343-4.366-1.55a2.38 2.38 0 1 0-1.591 4.488l4.366 1.55.966.342 1.625.576.965.343 2.591.92.967.342 1.624.577.966.342 4.367 1.55a2.38 2.38 0 0 0 3.04-1.447"

    /// OpenCode's official mark (Simple Icons `opencode`, viewBox 24×24).
    static let opencodePath = "M22 24H2V0h20zM17 4.8H7v14.4h10z"

    static func path(for brand: Brand) -> String {
        switch brand {
        case .claudeCode: claudeCodePath
        case .openai: openAIPath
        case .gemini: geminiPath
        case .copilot: copilotPath
        case .cursor: cursorPath
        case .qwen: qwenPath
        case .amp: ampPath
        case .opencode: opencodePath
        }
    }
}

extension Brand {
    /// The exact brand color of each mark.
    var brandColor: Color {
        switch self {
        case .claudeCode: Color(red: 0.851, green: 0.467, blue: 0.341)   // #D97757
        case .gemini: Color(red: 0.557, green: 0.459, blue: 0.698)       // #8E75B2
        case .qwen: Color(red: 0.412, green: 0.314, blue: 0.937)         // #6950EF
        case .openai, .copilot, .cursor, .amp, .opencode: .monochromeMark
        }
    }
}

extension Color {
    /// The monochrome brands ship one mark in two official finishes: black on
    /// light, reversed to white on dark. A literal black would simply vanish
    /// into Skylight's dark glass, so the mark follows the appearance — which
    /// is the official treatment, not a deviation from it. (Only the bare
    /// `filled: false` path reads this; the plated variant paints its own
    /// black-on-white, which is correct in both appearances.)
    static let monochromeMark = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : .black
    })
}

/// Provider logo at a given size. `filled` draws the official rounded-square
/// app-icon treatment; otherwise the bare transparent mark.
struct BrandIcon: View {
    let brand: Brand
    var size: CGFloat = 18
    var filled = true

    var body: some View {
        if filled {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(background)
                .frame(width: size, height: size)
                .overlay(mark(color: markColor).padding(size * 0.2))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
        } else {
            mark(color: brand.brandColor)
                .frame(width: size, height: size)
        }
    }

    private func mark(color: Color) -> some View {
        SVGShape(pathData: BrandMark.path(for: brand), viewBox: CGSize(width: 24, height: 24))
            .fill(color)
    }

    private var background: Color {
        switch brand {
        case .claudeCode: brand.brandColor
        case .openai, .gemini, .copilot, .cursor, .qwen, .amp, .opencode: Color.white
        }
    }

    private var markColor: Color {
        switch brand {
        case .claudeCode: .white
        case .gemini, .qwen: brand.brandColor
        case .openai, .copilot, .cursor, .amp, .opencode: .black
        }
    }
}

import AppKit
import SwiftUI

extension ChatProvider {
    @MainActor private static var logoCache: [ChatProvider: NSImage] = [:]

    @MainActor var logoImage: NSImage? {
        if let cached = Self.logoCache[self] { return cached }
        let name = self == .claude ? "claude-logo" : "chatgpt-logo"
        guard let url = Bundle.module.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        Self.logoCache[self] = image
        return image
    }
}

/// Official provider logo at a given size, rounded like a mini app icon.
/// Falls back to the SF Symbol if the bundled asset is missing.
struct BrandIcon: View {
    let provider: ChatProvider
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let image = provider.logoImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: provider.symbolName)
                    .font(.system(size: size * 0.7, weight: .medium))
                    .foregroundStyle(provider.tint)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

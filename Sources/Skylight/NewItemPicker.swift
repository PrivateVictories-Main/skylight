import SwiftUI

/// The "what do you want to open?" picker — big scrollable brand tiles for
/// chats and CLIs, with live install-state. Replaces a plain menu with the
/// over-the-top-but-simple selector the rest of the app deserves.
struct NewItemPicker: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    private struct ChatChoice: Identifiable {
        let provider: ChatProvider
        var id: String { provider.rawValue }
    }

    private struct ComingSoon: Identifiable {
        let id: String
        let name: String
        let symbol: String
        let note: String
    }

    private let chats = ChatProvider.allCases.map(ChatChoice.init)
    private let comingSoon = [
        ComingSoon(id: "grok", name: "Grok", symbol: "x.circle", note: "No official CLI yet"),
        ComingSoon(id: "copilot", name: "Copilot", symbol: "airplane.circle", note: "Planned"),
        ComingSoon(id: "opencode", name: "OpenCode", symbol: "cube", note: "Planned"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("New")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.pressable)
            }

            section("Chats", subtitle: "Native chat on your subscription") {
                ForEach(chats) { choice in
                    Tile(
                        title: choice.provider.displayName,
                        subtitle: installState(choice.provider),
                        installed: isInstalled(choice.provider)
                    ) {
                        BrandIcon(provider: choice.provider, size: 34)
                    } action: {
                        state.addAssistant(choice.provider)
                        dismiss()
                    }
                }
                ForEach(comingSoon) { entry in
                    Tile(title: entry.name, subtitle: entry.note, installed: false, enabled: false) {
                        Image(systemName: entry.symbol)
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(.tertiary)
                            .frame(width: 34, height: 34)
                    } action: {}
                }
            }

            section("Terminals", subtitle: "Real Ghostty terminals — plain shell or an agent CLI") {
                ForEach(TerminalFlavor.allCases, id: \.self) { flavor in
                    Tile(
                        title: flavor.displayName,
                        subtitle: flavor == .shell ? "zsh" : installState(flavor),
                        installed: flavor.command == nil || ProviderChatEngine.binary(for: flavor.provider ?? .claude) != nil
                    ) {
                        if let provider = flavor.provider {
                            BrandIcon(provider: provider, size: 34)
                                .overlay(alignment: .bottomTrailing) {
                                    Image(systemName: "terminal.fill")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.secondary)
                                        .padding(2)
                                        .background(Circle().fill(.background))
                                        .offset(x: 5, y: 5)
                                }
                        } else {
                            Image(systemName: "terminal")
                                .font(.system(size: 24, weight: .medium))
                                .foregroundStyle(.primary)
                                .frame(width: 34, height: 34)
                        }
                    } action: {
                        state.addTerminal(flavor)
                        dismiss()
                    }
                }
            }

            section("Boards", subtitle: "A canvas of live tiles") {
                Tile(title: "Canvas", subtitle: "Drag anything in", installed: true) {
                    Image(systemName: "square.on.square.dashed")
                        .font(.system(size: 24, weight: .medium))
                        .frame(width: 34, height: 34)
                } action: {
                    state.selection = .canvas(state.newCanvas().id)
                    dismiss()
                }
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    private func isInstalled(_ provider: ChatProvider) -> Bool {
        ProviderChatEngine.binary(for: provider) != nil
    }

    private func installState(_ provider: ChatProvider) -> String {
        isInstalled(provider) ? "Ready" : "Install \(ProviderChatEngine.cliName(for: provider)) CLI"
    }

    private func installState(_ flavor: TerminalFlavor) -> String {
        guard let provider = flavor.provider else { return "zsh" }
        return isInstalled(provider) ? "Interactive agent" : "Install \(ProviderChatEngine.cliName(for: provider)) CLI"
    }

    @ViewBuilder
    private func section(_ title: String, subtitle: String, @ViewBuilder tiles: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    tiles()
                }
                .padding(2)
            }
        }
    }

    private struct Tile<Icon: View>: View {
        let title: String
        let subtitle: String
        var installed: Bool
        var enabled: Bool = true
        @ViewBuilder let icon: () -> Icon
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                VStack(spacing: 8) {
                    icon()
                    VStack(spacing: 1) {
                        Text(title)
                            .font(.system(size: 12.5, weight: .medium))
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(installed ? Color.secondary : Color.orange)
                            .lineLimit(1)
                    }
                }
                .frame(width: 118, height: 92)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08))
                        )
                )
                .opacity(enabled ? 1 : 0.45)
            }
            .buttonStyle(.pressable(scale: 0.95))
            .disabled(!enabled)
        }
    }
}

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The custom, fully-native chat surface: our own message list, our own output
/// rendering, and a custom composer with attachments — no web input anywhere.
struct ProviderChatView: View {
    @ObservedObject var engine: ProviderChatEngine

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Composer(engine: engine)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Model", selection: $engine.modelID) {
                    ForEach(engine.provider.modelOptions) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()

                if engine.provider.supportsEffort {
                    Picker("Effort", selection: $engine.effort) {
                        ForEach(ReasoningEffort.allCases) { effort in
                            Text(effort.label).tag(effort)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(engine.messages) { message in
                        MessageRow(message: message, provider: engine.provider)
                            .id(message.id)
                    }
                    if engine.isThinking {
                        ThinkingRow(provider: engine.provider).id("thinking")
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
                .frame(maxWidth: 780)
                .frame(maxWidth: .infinity)
            }
            .overlay {
                if engine.messages.isEmpty, !engine.isThinking {
                    WelcomePanel(provider: engine.provider, missingCLI: engine.missingCLI)
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: engine.messages) {
                if let last = engine.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: engine.isThinking) {
                if engine.isThinking { withAnimation { proxy.scrollTo("thinking", anchor: .bottom) } }
            }
        }
    }
}

// MARK: - Messages

private struct MessageRow: View {
    let message: ChatMessage
    let provider: ChatProvider

    var body: some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 6) {
                if !message.attachments.isEmpty {
                    attachmentStrip
                }
                if !message.text.isEmpty {
                    HStack {
                        Spacer(minLength: 60)
                        Text(message.text)
                            .textSelection(.enabled)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.15))
                            )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            HStack(alignment: .top, spacing: 12) {
                BrandIcon(provider: provider, size: 24)
                Text(LocalizedStringKey(message.text))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .error:
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message.text)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }

    private var attachmentStrip: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            ForEach(message.attachments) { attachment in
                AttachmentChip(attachment: attachment, onRemove: nil)
            }
        }
    }
}

private struct ThinkingRow: View {
    let provider: ChatProvider
    @State private var pulse = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            BrandIcon(provider: provider, size: 24)
            HStack(spacing: 5) {
                ForEach(0 ..< 3) { index in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 6, height: 6)
                        .opacity(pulse ? 0.25 : 0.9)
                        .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(index) * 0.2), value: pulse)
                }
            }
            .padding(.top, 4)
            Spacer()
        }
        .onAppear { pulse = true }
    }
}

private struct WelcomePanel: View {
    let provider: ChatProvider
    let missingCLI: Bool

    var body: some View {
        VStack(spacing: 14) {
            BrandIcon(provider: provider, size: 46)
            Text(provider.displayName)
                .font(.title3.weight(.semibold))
            if missingCLI {
                let cli = provider == .claude ? "Claude Code" : "Codex"
                let cmd = provider == .claude ? "npm i -g @anthropic-ai/claude-code" : "npm i -g @openai/codex"
                Text("Install the \(cli) CLI to chat natively on your subscription:\n\(cmd)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Runs natively on your \(provider.displayName) subscription.\nAsk anything, attach files — the conversation continues across restarts.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 440)
    }
}

// MARK: - Attachments

private struct AttachmentChip: View {
    let attachment: ChatAttachment
    let onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            if attachment.isImage, let image = NSImage(contentsOfFile: attachment.path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Image(systemName: attachment.isImage ? "photo" : "doc")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
            }
            Text(attachment.name)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .frame(maxWidth: 120)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 5)
        .padding(.trailing, onRemove == nil ? 9 : 5)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(Color(nsColor: .controlBackgroundColor))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        )
    }
}

// MARK: - Composer

private struct Composer: View {
    @ObservedObject var engine: ProviderChatEngine
    @State private var draft = ""
    @State private var attachments: [ChatAttachment] = []
    @FocusState private var focused: Bool

    private var canSend: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) && !engine.isThinking
    }

    var body: some View {
        VStack(spacing: 8) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachments) { attachment in
                            AttachmentChip(attachment: attachment) {
                                attachments.removeAll { $0.id == attachment.id }
                            }
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                Button(action: pickAttachments) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 6)
                .help("Attach files or images")

                TextField(engine.provider.composerPlaceholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1 ... 10)
                    .focused($focused)
                    .onSubmit(send)
                    .font(.system(size: 14))

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .padding(.bottom, 1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12))
                    )
            )
        }
        .padding(14)
        .frame(maxWidth: 780)
        .frame(maxWidth: .infinity)
        .onAppear { focused = true }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in add(url) } }
                }
            }
            return true
        }
    }

    private func send() {
        guard canSend else { return }
        engine.send(draft, attachments: attachments)
        draft = ""
        attachments = []
    }

    private func pickAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            for url in panel.urls { add(url) }
        }
    }

    private func add(_ url: URL) {
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff"]
        let isImage = imageExts.contains(url.pathExtension.lowercased())
        attachments.append(ChatAttachment(path: url.path, name: url.lastPathComponent, isImage: isImage))
    }
}

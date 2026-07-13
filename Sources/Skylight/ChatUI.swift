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
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(engine.messages) { message in
                        MessageRow(message: message, provider: engine.provider)
                            .id(message.id)
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }
                    if let streaming = engine.streamingText, !streaming.isEmpty {
                        HStack(alignment: .top, spacing: 12) {
                            BrandIcon(provider: engine.provider, size: 24)
                            RichMessageText(text: streaming)
                        }
                        .id("thinking")
                    } else if engine.isThinking {
                        ThinkingRow(provider: engine.provider).id("thinking")
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
                .frame(maxWidth: 780)
                .frame(maxWidth: .infinity)
                .animation(.spring(response: 0.35, dampingFraction: 0.82), value: engine.messages)
            }
            .overlay {
                if engine.messages.isEmpty, !engine.isThinking {
                    WelcomePanel(provider: engine.provider, missingCLI: engine.missingCLI) { prompt in
                        engine.send(prompt, attachments: [])
                    }
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
            .onChange(of: engine.streamingText) {
                proxy.scrollTo("thinking", anchor: .bottom)
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
                RichMessageText(text: message.text)
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
    var onSuggestion: ((String) -> Void)?

    private var suggestions: [(String, String)] {
        switch provider {
        case .claude:
            [("lightbulb", "Brainstorm ideas for a side project"),
             ("doc.text", "Summarize a file I attach"),
             ("wand.and.stars", "Improve a paragraph I paste")]
        case .chatgpt:
            [("chevron.left.forwardslash.chevron.right", "Explain a piece of code I paste"),
             ("ladybug", "Help me debug an error message"),
             ("square.grid.2x2", "Sketch an app architecture with me")]
        case .gemini:
            [("globe", "Research a topic and cite sources"),
             ("doc.richtext", "Draft a document outline"),
             ("questionmark.circle", "Quiz me on something I'm learning")]
        }
    }

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
                Text("Runs natively on your \(provider.displayName) subscription.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                VStack(spacing: 8) {
                    ForEach(suggestions, id: \.1) { symbol, prompt in
                        Button {
                            onSuggestion?(prompt)
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: symbol)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                Text(prompt)
                                    .font(.system(size: 12.5))
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 13)
                            .padding(.vertical, 9)
                            .frame(width: 300)
                            .background(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                                            .strokeBorder(Color.primary.opacity(0.08))
                                    )
                            )
                        }
                        .buttonStyle(.pressable(scale: 0.97))
                    }
                }
                .padding(.top, 6)
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

    private var sendColor: Color {
        if engine.isThinking { return .primary }
        return canSend ? .accentColor : Color.secondary.opacity(0.45)
    }

    private var composerBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        let border: Color = Color.primary.opacity(0.1)
        let shadow: Color = Color.black.opacity(0.06)
        return shape
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(shape.strokeBorder(border))
            .shadow(color: shadow, radius: 8, y: 2)
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
            // ChatGPT-app-style composer card: input on top, controls below.
            VStack(spacing: 6) {
                TextField(engine.provider.composerPlaceholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1 ... 10)
                    .focused($focused)
                    .onSubmit(send)
                    .font(.system(size: 14))
                    .padding(.horizontal, 4)
                    .padding(.top, 4)

                HStack(spacing: 10) {
                    Button(action: pickAttachments) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.pressable)
                    .help("Attach files or images")

                    Spacer()

                    ModelPill(engine: engine)

                    Button {
                        if engine.isThinking { engine.stop() } else { send() }
                    } label: {
                        Image(systemName: engine.isThinking ? "stop.circle.fill" : "arrow.up.circle.fill")
                            .font(.system(size: 27))
                            .foregroundStyle(sendColor)
                            .symbolEffect(.bounce, value: engine.messages.count)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.pressable(scale: 0.86))
                    .disabled(!canSend && !engine.isThinking)
                    .help(engine.isThinking ? "Stop generating" : "Send")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(composerBackground)
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

/// The combined model + effort pill, like the ChatGPT app's "5.6 Sol Ultra".
private struct ModelPill: View {
    @ObservedObject var engine: ProviderChatEngine

    private var label: String {
        let model = engine.provider.modelOptions.first { $0.id == engine.modelID }?.label ?? "Default"
        if engine.provider.supportsEffort, engine.modelID.isEmpty == false || !engine.effortOptions.isEmpty {
            return "\(model) · \(engine.effort.capitalized)"
        }
        return model
    }

    @State private var showPanel = false

    var body: some View {
        Button {
            showPanel = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9, weight: .semibold))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(0.05)))
        }
        .buttonStyle(.pressable(scale: 0.96))
        .popover(isPresented: $showPanel, arrowEdge: .top) {
            ModelEffortPanel(engine: engine)
        }
    }
}

/// The model + effort control surface: pressable model rows, and reasoning
/// effort as a draggable snapping slider.
private struct ModelEffortPanel: View {
    @ObservedObject var engine: ProviderChatEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Model")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                VStack(spacing: 2) {
                    ForEach(engine.provider.modelOptions) { option in
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                engine.modelID = option.id
                            }
                        } label: {
                            HStack {
                                Text(option.label)
                                    .font(.system(size: 12.5,
                                                  weight: engine.modelID == option.id ? .semibold : .regular))
                                Spacer()
                                if engine.modelID == option.id {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight(cornerRadius: 8, active: engine.modelID == option.id)
                    }
                }
            }

            if engine.provider.supportsEffort {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Reasoning Effort")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(engine.effort.capitalized)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .contentTransition(.numericText())
                            .animation(.spring(response: 0.3), value: engine.effort)
                    }
                    StopSlider(options: engine.effortOptions, selection: $engine.effort)
                    HStack {
                        Text(engine.effortOptions.first?.capitalized ?? "")
                        Spacer()
                        Text(engine.effortOptions.last?.capitalized ?? "")
                    }
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                }
            }
        }
        .padding(16)
        .frame(width: 264)
    }
}

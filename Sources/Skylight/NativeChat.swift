import Foundation
import SwiftUI

// MARK: - Model

struct ChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable {
        case user
        case assistant
        case error
    }

    let id: UUID
    var role: Role
    var text: String
    var date: Date

    init(id: UUID = UUID(), role: Role, text: String, date: Date = .now) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
    }
}

enum ClaudeModel: String, Codable, CaseIterable, Identifiable {
    case defaultModel = ""
    case fable = "claude-fable-5"
    case opus = "opus"
    case sonnet = "sonnet"
    case haiku = "haiku"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .defaultModel: "Default"
        case .fable: "Fable 5"
        case .opus: "Opus 4.8"
        case .sonnet: "Sonnet 5"
        case .haiku: "Haiku 4.5"
        }
    }
}

// MARK: - Engine

/// Native chat over the user's existing Claude subscription, via the Claude
/// Code CLI (`claude -p --output-format json`). No web view, no private APIs —
/// the CLI is the vendor-sanctioned surface and handles auth itself.
@MainActor
final class NativeChatEngine: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isThinking = false
    @Published var model: ClaudeModel = .defaultModel {
        didSet { save() }
    }

    private var sessionID: String?
    private let itemID: UUID

    init(itemID: UUID) {
        self.itemID = itemID
        load()
    }

    // MARK: Transcript persistence

    private var transcriptURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Skylight/chats", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(itemID.uuidString).json")
    }

    private struct SavedChat: Codable {
        var messages: [ChatMessage]
        var sessionID: String?
        var model: ClaudeModel?
    }

    private func load() {
        guard let data = try? Data(contentsOf: transcriptURL),
              let saved = try? JSONDecoder().decode(SavedChat.self, from: data) else { return }
        messages = saved.messages
        sessionID = saved.sessionID
        model = saved.model ?? .defaultModel
    }

    private func save() {
        let saved = SavedChat(messages: messages, sessionID: sessionID, model: model)
        if let data = try? JSONEncoder().encode(saved) {
            try? data.write(to: transcriptURL)
        }
    }

    // MARK: Sending

    func send(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isThinking else { return }
        messages.append(ChatMessage(role: .user, text: trimmed))
        isThinking = true
        save()

        let resume = sessionID
        let modelArg = model.rawValue
        Task.detached { [weak self] in
            let outcome = Self.runClaude(prompt: trimmed, model: modelArg, resume: resume)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isThinking = false
                switch outcome {
                case let .success(reply, newSession):
                    self.sessionID = newSession ?? self.sessionID
                    self.messages.append(ChatMessage(role: .assistant, text: reply))
                case let .failure(message):
                    self.messages.append(ChatMessage(role: .error, text: message))
                }
                self.save()
            }
        }
    }

    private enum Outcome: Sendable {
        case success(String, String?)
        case failure(String)
    }

    nonisolated private static func claudeBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated private static func runClaude(prompt: String, model: String, resume: String?) -> Outcome {
        guard let binary = claudeBinary() else {
            return .failure("Couldn't find the `claude` CLI. Install Claude Code and log in once from a terminal.")
        }
        var arguments = ["-p", prompt, "--output-format", "json"]
        if !model.isEmpty { arguments += ["--model", model] }
        if let resume { arguments += ["--resume", resume] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return .failure("Couldn't launch claude: \(error.localizedDescription)")
        }
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let json = try? JSONSerialization.jsonObject(with: outData) as? [String: Any],
              let result = json["result"] as? String
        else {
            let err = String(data: errData, encoding: .utf8) ?? ""
            let out = String(data: outData, encoding: .utf8) ?? ""
            return .failure("Claude didn't return a result.\n\(err.isEmpty ? out : err)")
        }
        if json["is_error"] as? Bool == true {
            return .failure(result)
        }
        return .success(result, json["session_id"] as? String)
    }
}

// MARK: - View

struct NativeChatView: View {
    @ObservedObject var engine: NativeChatEngine
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(engine.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                        if engine.isThinking {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Thinking…")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .id("thinking")
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
                .overlay {
                    if engine.messages.isEmpty, !engine.isThinking {
                        emptyState
                    }
                }
                .onChange(of: engine.messages) {
                    if let last = engine.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onChange(of: engine.isThinking) {
                    if engine.isThinking {
                        withAnimation { proxy.scrollTo("thinking", anchor: .bottom) }
                    }
                }
            }
            inputBar
        }
        .background(Color(nsColor: .textBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Model", selection: $engine.model) {
                    ForEach(ClaudeModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            BrandIcon(provider: .claude, size: 44)
            Text("Claude")
                .font(.title3.weight(.semibold))
            Text("Runs natively on your Claude subscription.\nPick a model from the toolbar — conversations continue across restarts.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 420)
        .allowsHitTesting(false)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message Claude…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1 ... 8)
                .focused($inputFocused)
                .onSubmit(sendDraft)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.12))
                        )
                )
            Button(action: sendDraft) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(draft.isEmpty || engine.isThinking ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(draft.isEmpty || engine.isThinking)
            .padding(.bottom, 4)
        }
        .padding(12)
        .background(.bar)
        .onAppear { inputFocused = true }
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        engine.send(text)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.accentColor.opacity(0.16))
                    )
            }
        case .assistant:
            Text(LocalizedStringKey(message.text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .error:
            Label {
                Text(message.text)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .font(.callout)
            .foregroundStyle(.orange)
        }
    }
}

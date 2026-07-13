import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

struct ChatAttachment: Identifiable, Codable, Equatable {
    let id: UUID
    var path: String
    var name: String
    var isImage: Bool

    init(id: UUID = UUID(), path: String, name: String, isImage: Bool) {
        self.id = id
        self.path = path
        self.name = name
        self.isImage = isImage
    }
}

struct ChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable {
        case user
        case assistant
        case error
    }

    let id: UUID
    var role: Role
    var text: String
    var attachments: [ChatAttachment]
    var date: Date

    init(id: UUID = UUID(), role: Role, text: String, attachments: [ChatAttachment] = [], date: Date = .now) {
        self.id = id
        self.role = role
        self.text = text
        self.attachments = attachments
        self.date = date
    }
}

// MARK: - Model / effort options per provider

struct ModelOption: Identifiable, Hashable {
    let id: String    // CLI value ("" = default)
    let label: String
}

extension ChatProvider {
    /// Model choices surfaced in the composer, per provider. ChatGPT/Codex is
    /// read live from the CLI's own model cache so it always matches the plan.
    var modelOptions: [ModelOption] {
        switch self {
        case .claude:
            [.init(id: "", label: "Default"),
             .init(id: "claude-fable-5", label: "Fable 5"),
             .init(id: "opus", label: "Opus 4.8"),
             .init(id: "sonnet", label: "Sonnet 5"),
             .init(id: "haiku", label: "Haiku 4.5")]
        case .chatgpt:
            [.init(id: "", label: "Default")]
                + CodexCatalog.load().map { .init(id: $0.slug, label: $0.displayName) }
        case .gemini:
            [.init(id: "", label: "Default"),
             .init(id: "gemini-3.1-pro", label: "Gemini 3.1 Pro"),
             .init(id: "gemini-3-pro", label: "Gemini 3 Pro"),
             .init(id: "gemini-3-flash", label: "Gemini 3 Flash")]
        }
    }

    /// Codex exposes reasoning effort; Claude Code and Gemini do not.
    var supportsEffort: Bool { self == .chatgpt }

    var composerPlaceholder: String { "Message \(displayName)…" }
}

// MARK: - Engine

/// Native chat over the user's existing subscription, driven by the provider's
/// own CLI (Claude Code `claude -p`, or Codex `codex exec`). No web view, no
/// private APIs — the CLI is the sanctioned surface and handles auth itself.
@MainActor
final class ProviderChatEngine: ObservableObject {
    let provider: ChatProvider

    @Published var messages: [ChatMessage] = []
    @Published var isThinking = false
    /// Partial assistant text while a reply streams in; nil when idle.
    @Published var streamingText: String?
    private var activeProcess: Process?
    @Published var modelID: String = "" { didSet { reconcileEffort(); save() } }
    @Published var effort: String = "medium" { didSet { save() } }
    @Published var missingCLI = false

    let codexModels: [CodexModel]
    /// Called with a derived conversation title on the first user message.
    var onTitle: ((String) -> Void)?
    /// Called with a model-written summary title after the first exchange.
    var onTitleRefined: ((String) -> Void)?
    private var sessionID: String?
    private let itemID: UUID

    init(provider: ChatProvider, itemID: UUID) {
        self.provider = provider
        self.itemID = itemID
        self.codexModels = provider == .chatgpt ? CodexCatalog.load() : []
        load()
        missingCLI = Self.binary(for: provider) == nil
    }

    /// Effort choices valid for the currently-selected Codex model.
    var effortOptions: [String] {
        guard provider == .chatgpt else { return [] }
        if let model = codexModels.first(where: { $0.slug == modelID }) {
            return model.efforts
        }
        return codexModels.first?.efforts ?? ["low", "medium", "high", "xhigh"]
    }

    /// Keep the selected effort valid when the model changes.
    private func reconcileEffort() {
        let options = effortOptions
        if !options.isEmpty, !options.contains(effort) {
            if let modelDefault = codexModels.first(where: { $0.slug == modelID })?.defaultEffort,
               options.contains(modelDefault) {
                effort = modelDefault
            } else {
                effort = options.contains("medium") ? "medium" : options[0]
            }
        }
    }

    // MARK: Persistence

    private var transcriptURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Skylight/chats", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(itemID.uuidString).json")
    }

    private struct SavedChat: Codable {
        var messages: [ChatMessage]
        var sessionID: String?
        var modelID: String?
        var effort: String?
    }

    private func load() {
        guard let data = try? Data(contentsOf: transcriptURL),
              let saved = try? JSONDecoder().decode(SavedChat.self, from: data) else { return }
        messages = saved.messages
        sessionID = saved.sessionID
        modelID = saved.modelID ?? ""
        effort = saved.effort ?? "medium"
    }

    private func save() {
        let saved = SavedChat(messages: messages, sessionID: sessionID, modelID: modelID, effort: effort)
        if let data = try? JSONEncoder().encode(saved) {
            try? data.write(to: transcriptURL)
        }
    }

    // MARK: Sending

    func send(_ prompt: String, attachments: [ChatAttachment]) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!trimmed.isEmpty || !attachments.isEmpty), !isThinking else { return }
        let isFirst = messages.isEmpty
        messages.append(ChatMessage(role: .user, text: trimmed, attachments: attachments))
        if isFirst {
            onTitle?(Self.deriveTitle(from: trimmed, attachments: attachments))
        }
        isThinking = true
        streamingText = nil
        save()

        let prompt = trimmed.isEmpty ? "(see attached)" : trimmed
        let imagePaths = attachments.filter(\.isImage).map(\.path)
        startStreaming(prompt: prompt, imagePaths: imagePaths)
    }

    /// Stops the in-flight reply, keeping whatever streamed so far.
    func stop() {
        activeProcess?.terminate()
    }

    /// Recent turns rendered as a prompt prefix, for stateless CLIs (Gemini).
    private func conversationContext() -> String {
        let recent = messages.suffix(9).dropLast()   // exclude the just-appended user turn
        guard !recent.isEmpty else { return "" }
        let lines = recent.compactMap { message -> String? in
            switch message.role {
            case .user: "User: \(message.text)"
            case .assistant: "Assistant: \(message.text)"
            case .error: nil
            }
        }
        guard !lines.isEmpty else { return "" }
        return "Earlier in this conversation:\n" + lines.joined(separator: "\n") + "\n\nNow the user says: "
    }

    /// A short, human-readable title from the first message — like ChatGPT/Claude.
    static func deriveTitle(from text: String, attachments: [ChatAttachment]) -> String {
        var t = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Collapse runs of whitespace.
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        if t.isEmpty {
            return attachments.first.map { $0.name } ?? "New Chat"
        }
        let maxLen = 44
        if t.count <= maxLen { return t }
        // Cut on a word boundary near the limit.
        let clipped = String(t.prefix(maxLen))
        if let lastSpace = clipped.lastIndex(of: " "), clipped.distance(from: clipped.startIndex, to: lastSpace) > 20 {
            return String(clipped[..<lastSpace]) + "…"
        }
        return clipped + "…"
    }

    // MARK: Streaming

    nonisolated static func cliName(for provider: ChatProvider) -> String {
        switch provider {
        case .claude: "claude"
        case .chatgpt: "codex"
        case .gemini: "gemini"
        }
    }

    nonisolated static func binary(for provider: ChatProvider) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let name = cliName(for: provider)
        let candidates = ["\(home)/.local/bin/\(name)", "/usr/local/bin/\(name)", "/opt/homebrew/bin/\(name)"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func startStreaming(prompt: String, imagePaths: [String]) {
        guard let binary = Self.binary(for: provider) else {
            let cli = provider == .claude ? "Claude Code" : "Codex"
            finish(error: "Couldn't find the \(cli) CLI. Install it and log in once from a terminal.")
            return
        }

        var arguments: [String]
        switch provider {
        case .claude:
            var fullPrompt = prompt
            if !imagePaths.isEmpty {
                fullPrompt += "\n\nAttached files:\n" + imagePaths.joined(separator: "\n")
            }
            arguments = ["-p", fullPrompt, "--output-format", "stream-json",
                         "--include-partial-messages", "--verbose"]
            if !modelID.isEmpty { arguments += ["--model", modelID] }
            if let resume = sessionID { arguments += ["--resume", resume] }
        case .chatgpt:
            arguments = ["exec", "--skip-git-repo-check", "--json"]
            if let resume = sessionID { arguments.insert(contentsOf: ["resume", resume], at: 1) }
            if !modelID.isEmpty { arguments += ["-m", modelID] }
            arguments += ["-c", "model_reasoning_effort=\"\(effort)\""]
            for path in imagePaths { arguments += ["-i", path] }
            arguments.append(prompt)
        case .gemini:
            // Gemini CLI is stateless in -p mode: replay recent turns for context.
            var fullPrompt = conversationContext() + prompt
            if !imagePaths.isEmpty {
                fullPrompt += "\n\nAttached files:\n" + imagePaths.joined(separator: "\n")
            }
            arguments = ["-p", fullPrompt, "--output-format", "json"]
            if !modelID.isEmpty { arguments += ["-m", modelID] }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = env

        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        activeProcess = process

        let providerKind = provider
        let lineBuffer = LineBuffer()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            // Gemini prints one JSON document, not JSONL — collect and parse at exit.
            let lines = lineBuffer.append(chunk)
            guard providerKind != .gemini else { return }
            for lineData in lines {
                Task { @MainActor [weak self] in
                    guard let event = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { return }
                    self?.handleEvent(event, provider: providerKind)
                }
            }
        }

        process.terminationHandler = { [weak self] proc in
            stdout.fileHandleForReading.readabilityHandler = nil
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(data: errData, encoding: .utf8) ?? ""
            let fullOutput = lineBuffer.allData()
            Task { @MainActor [weak self] in
                guard let self else { return }
                if providerKind == .gemini, self.isThinking {
                    if let json = try? JSONSerialization.jsonObject(with: fullOutput) as? [String: Any],
                       let response = json["response"] as? String, !response.isEmpty {
                        self.streamingText = response
                    } else if let text = String(data: fullOutput, encoding: .utf8),
                              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.streamingText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                self.processEnded(status: proc.terminationStatus, stderr: stderrText)
            }
        }

        do {
            try process.run()
        } catch {
            activeProcess = nil
            finish(error: "Couldn't launch \(provider == .claude ? "claude" : "codex"): \(error.localizedDescription)")
        }
    }

    /// One JSONL event from either CLI → streaming state updates.
    private func handleEvent(_ event: [String: Any], provider: ChatProvider) {
        switch provider {
        case .claude:
            switch event["type"] as? String {
            case "stream_event":
                if let inner = event["event"] as? [String: Any],
                   inner["type"] as? String == "content_block_delta",
                   let delta = inner["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let text = delta["text"] as? String {
                    streamingText = (streamingText ?? "") + text
                }
            case "result":
                if let session = event["session_id"] as? String { sessionID = session }
                let result = event["result"] as? String
                if event["is_error"] as? Bool == true {
                    finish(error: result ?? "Claude returned an error.")
                } else if let result, !result.isEmpty {
                    // Authoritative final text.
                    streamingText = result
                }
            default:
                break
            }
        case .chatgpt:
            switch event["type"] as? String {
            case "thread.started":
                if let thread = event["thread_id"] as? String { sessionID = thread }
            case "item.updated", "item.completed":
                if let item = event["item"] as? [String: Any],
                   item["item_type"] as? String == "agent_message",
                   let text = item["text"] as? String {
                    streamingText = text
                }
            case "error":
                if let message = event["message"] as? String {
                    finish(error: message)
                }
            default:
                break
            }
        case .gemini:
            break   // Gemini output is parsed whole at process exit.
        }
    }

    private func processEnded(status: Int32, stderr: String) {
        activeProcess = nil
        guard isThinking else { return }   // already finished via an error event
        if let text = streamingText, !text.isEmpty {
            finish(reply: text.trimmingCharacters(in: .whitespacesAndNewlines))
        } else if status == 0 {
            finish(error: "No reply received.")
        } else if status == 15 {           // SIGTERM: user pressed stop
            finish(error: "Stopped.")
        } else {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            finish(error: detail.isEmpty ? "The model exited unexpectedly (code \(status))." : detail)
        }
    }

    private func finish(reply: String? = nil, error: String? = nil) {
        isThinking = false
        streamingText = nil
        if let reply { messages.append(ChatMessage(role: .assistant, text: reply)) }
        if let error { messages.append(ChatMessage(role: .error, text: error)) }
        save()
        if reply != nil, messages.filter({ $0.role == .assistant }).count == 1 {
            refineTitle()
        }
    }

    /// After the first exchange, ask a fast model for a proper 3–6 word title —
    /// the same quiet upgrade ChatGPT and Claude do a moment after you start.
    private func refineTitle() {
        guard let userText = messages.first(where: { $0.role == .user })?.text,
              let assistantText = messages.last(where: { $0.role == .assistant })?.text,
              let binary = Self.binary(for: .claude) else { return }
        let excerpt = "User: \(userText.prefix(400))\nAssistant: \(assistantText.prefix(400))"
        let prompt = "Write a title for this conversation: 3 to 6 words, no quotes, no trailing period, just the title.\n\n\(excerpt)"

        Task.detached { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["-p", prompt, "--model", "haiku"]
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  var title = String(data: data, encoding: .utf8)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty, title.count <= 64
            else { return }
            title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'."))
            await MainActor.run { [weak self] in
                self?.onTitleRefined?(title)
            }
        }
    }
}

/// Accumulates pipe chunks and splits complete newline-terminated lines.
/// Locked because readabilityHandler runs on a background queue.
private final class LineBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    private var everything = Data()

    func append(_ chunk: Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        everything.append(chunk)
        data.append(chunk)
        var lines: [Data] = []
        while let newline = data.firstIndex(of: 0x0A) {
            lines.append(Data(data.prefix(upTo: newline)))
            data.removeSubrange(...newline)
        }
        return lines
    }

    func allData() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return everything
    }
}

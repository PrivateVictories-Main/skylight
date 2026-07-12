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
        }
    }

    /// Codex exposes reasoning effort; Claude Code does not.
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
    @Published var modelID: String = "" { didSet { reconcileEffort(); save() } }
    @Published var effort: String = "medium" { didSet { save() } }
    @Published var missingCLI = false

    let codexModels: [CodexModel]
    /// Called with a derived conversation title on the first user message.
    var onTitle: ((String) -> Void)?
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
        save()

        let request = Request(
            provider: provider,
            prompt: trimmed.isEmpty ? "(see attached)" : trimmed,
            model: modelID,
            effort: provider.supportsEffort ? effort : nil,
            imagePaths: attachments.filter(\.isImage).map(\.path),
            resume: sessionID
        )
        Task.detached { [weak self] in
            let outcome = Self.run(request)
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

    private struct Request: Sendable {
        let provider: ChatProvider
        let prompt: String
        let model: String
        let effort: String?
        let imagePaths: [String]
        let resume: String?
    }

    private enum Outcome: Sendable {
        case success(String, String?)
        case failure(String)
    }

    nonisolated private static func binary(for provider: ChatProvider) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let name = provider == .claude ? "claude" : "codex"
        let candidates = ["\(home)/.local/bin/\(name)", "/usr/local/bin/\(name)", "/opt/homebrew/bin/\(name)"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated private static func run(_ request: Request) -> Outcome {
        guard let binary = binary(for: request.provider) else {
            let cli = request.provider == .claude ? "Claude Code" : "Codex"
            return .failure("Couldn't find the \(cli) CLI. Install it and log in once from a terminal.")
        }
        switch request.provider {
        case .claude: return runClaude(binary: binary, request: request)
        case .chatgpt: return runCodex(binary: binary, request: request)
        }
    }

    nonisolated private static func runClaude(binary: String, request: Request) -> Outcome {
        var arguments = ["-p", request.prompt, "--output-format", "json"]
        if !request.model.isEmpty { arguments += ["--model", request.model] }
        if let resume = request.resume { arguments += ["--resume", resume] }
        // Claude Code reads images from paths mentioned in the prompt; append them.
        if !request.imagePaths.isEmpty {
            arguments[1] += "\n\nAttached files:\n" + request.imagePaths.joined(separator: "\n")
        }
        guard let out = launch(binary, arguments) else {
            return .failure("Couldn't launch claude.")
        }
        guard let json = try? JSONSerialization.jsonObject(with: out.data) as? [String: Any],
              let result = json["result"] as? String else {
            return .failure(out.stderr.isEmpty ? "Claude didn't return a result." : out.stderr)
        }
        if json["is_error"] as? Bool == true { return .failure(result) }
        return .success(result, json["session_id"] as? String)
    }

    nonisolated private static func runCodex(binary: String, request: Request) -> Outcome {
        // Write the final assistant message to a temp file for clean capture.
        let outFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("skylight-codex-\(UUID().uuidString).txt")
        var arguments = ["exec", "--skip-git-repo-check", "-o", outFile.path]
        if !request.model.isEmpty { arguments += ["-m", request.model] }
        if let effort = request.effort { arguments += ["-c", "model_reasoning_effort=\"\(effort)\""] }
        for path in request.imagePaths { arguments += ["-i", path] }
        if request.resume != nil { arguments.insert("resume", at: 1); arguments.insert("--last", at: 2) }
        arguments.append(request.prompt)

        guard let out = launch(binary, arguments) else {
            return .failure("Couldn't launch codex.")
        }
        if let reply = try? String(contentsOf: outFile, encoding: .utf8) {
            try? FileManager.default.removeItem(at: outFile)
            let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return .success(trimmed, nil) }
        }
        let fallback = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fallback.isEmpty { return .success(fallback, nil) }
        return .failure(out.stderr.isEmpty ? "Codex didn't return a result." : out.stderr)
    }

    private struct Launched { let data: Data; let stdout: String; let stderr: String }

    nonisolated private static func launch(_ binary: String, _ arguments: [String]) -> Launched? {
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
        do { try process.run() } catch { return nil }
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Launched(
            data: outData,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}

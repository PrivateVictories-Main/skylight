import Foundation

/// Reads Codex's own model cache (~/.codex/models_cache.json) so Skylight's
/// model + reasoning-effort pickers always match what the installed CLI and the
/// user's plan actually offer — no hard-coded, drifting model list.
struct CodexModel: Identifiable, Hashable {
    let slug: String
    let displayName: String
    let efforts: [String]
    let defaultEffort: String

    var id: String { slug }
}

enum CodexCatalog {
    /// Fallback used only if the cache file is missing/unreadable.
    static let fallback: [CodexModel] = [
        CodexModel(slug: "gpt-5.6-sol", displayName: "GPT-5.6 Sol",
                   efforts: ["low", "medium", "high", "xhigh", "max", "ultra"], defaultEffort: "medium"),
        CodexModel(slug: "gpt-5.6-terra", displayName: "GPT-5.6 Terra",
                   efforts: ["low", "medium", "high", "xhigh", "max", "ultra"], defaultEffort: "medium"),
        CodexModel(slug: "gpt-5.6-luna", displayName: "GPT-5.6 Luna",
                   efforts: ["low", "medium", "high", "xhigh", "max"], defaultEffort: "medium"),
    ]

    private static var cacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/models_cache.json")
    }

    static func load() -> [CodexModel] {
        guard let data = try? Data(contentsOf: cacheURL),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            return fallback
        }
        var models: [CodexModel] = []
        var seen = Set<String>()
        walk(root) { dict in
            guard let slug = dict["slug"] as? String,
                  let display = dict["display_name"] as? String,
                  let levels = dict["supported_reasoning_levels"] as? [[String: Any]],
                  dict["visibility"] as? String != "hide",
                  !seen.contains(slug)
            else { return }
            let efforts = levels.compactMap { $0["effort"] as? String }
            guard !efforts.isEmpty else { return }
            seen.insert(slug)
            models.append(CodexModel(
                slug: slug,
                displayName: display.replacingOccurrences(of: "-", with: " "),
                efforts: efforts,
                defaultEffort: dict["default_reasoning_level"] as? String ?? "medium"
            ))
        }
        return models.isEmpty ? fallback : latestTwoGenerations(of: models)
    }

    /// Only the newest model generation and the one before it — nobody wants
    /// a graveyard of deprecated models in the picker.
    static func latestTwoGenerations(of models: [CodexModel]) -> [CodexModel] {
        func generation(_ slug: String) -> Double? {
            guard let range = slug.range(of: #"gpt-(\d+(?:\.\d+)?)"#, options: .regularExpression) else { return nil }
            return Double(slug[range].dropFirst(4))
        }
        let generations = Set(models.compactMap { generation($0.slug) }).sorted(by: >)
        guard generations.count > 2 else { return models }
        let keep = Set(generations.prefix(2))
        return models.filter { model in
            guard let gen = generation(model.slug) else { return false }
            return keep.contains(gen)
        }
    }

    private static func walk(_ node: Any, _ visit: ([String: Any]) -> Void) {
        if let dict = node as? [String: Any] {
            visit(dict)
            for value in dict.values { walk(value, visit) }
        } else if let array = node as? [Any] {
            for item in array { walk(item, visit) }
        }
    }
}

import Foundation

/// Search metadata only. Terminal output and command input never enter the index.
public enum WorkspaceSearch {
    public struct Item: Identifiable, Equatable, Sendable {
        public enum Kind: Sendable { case terminal, canvas, preset }
        public let id: UUID
        public let kind: Kind
        public let title: String
        public let detail: String

        public init(id: UUID, kind: Kind, title: String, detail: String) {
            self.id = id
            self.kind = kind
            self.title = title
            self.detail = detail
        }
    }

    public static func presetItem(_ preset: LaunchPreset) -> Item {
        let spec = preset.resolvedSpec(for: .macos)
        let tool = spec.harness.flatMap { Catalog.harness($0)?.displayName }
            ?? spec.harness ?? "Terminal"
        return Item(id: preset.id, kind: .preset, title: preset.name,
                    detail: ["Launch preset", tool, spec.workingDirectory]
                        .compactMap { $0 }.joined(separator: " · "))
    }

    public static func results(for query: String, in items: [Item]) -> [Item] {
        let query = normalized(query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return items.enumerated().compactMap { index, item -> (Item, Int, Int)? in
            let title = normalized(item.title)
            let searchable = title + " " + normalized(item.detail)
            guard words.allSatisfy({ searchable.contains($0) }) else { return nil }
            let rank = title == query ? 0 : title.hasPrefix(query) ? 1 : title.contains(query) ? 2 : 3
            return (item, rank, index)
        }
        .sorted { ($0.1, $0.2) < ($1.1, $1.2) }
        .map(\.0)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive],
                      locale: Locale(identifier: "en_US_POSIX"))
    }
}

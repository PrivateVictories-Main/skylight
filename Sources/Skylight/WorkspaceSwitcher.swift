import SwiftUI
import SkylightCore

/// A transient keyboard-first surface; the workspace keeps all permanent chrome.
struct WorkspaceSwitcher: View {
    @EnvironmentObject private var state: AppState
    @State private var query = ""
    @State private var selectedID: UUID?

    private var items: [WorkspaceSearch.Item] {
        state.instances.map { instance in
            let board = Residency.board(of: instance.id, in: state.canvases)
                .flatMap { id in state.canvases.first { $0.id == id }?.name }
            let harness = instance.spec.harness.flatMap { Catalog.harness($0)?.displayName }
            let directory = state.sessions.existingTerminal(for: instance.id)?.workingDirectory
                ?? instance.spec.workingDirectory
            return WorkspaceSearch.Item(
                id: instance.id, kind: .terminal, title: instance.name,
                detail: [harness ?? "Terminal", board, directory].compactMap { $0 }.joined(separator: " · "))
        } + state.canvases.map {
            WorkspaceSearch.Item(id: $0.id, kind: .canvas, title: $0.name,
                                 detail: "Canvas · \(state.residents(of: $0).count) sessions")
        } + state.presets.map(WorkspaceSearch.presetItem)
    }

    private var results: [WorkspaceSearch.Item] {
        WorkspaceSearch.results(for: query, in: items)
    }

    var body: some View {
        let matches = results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                WorkspaceSearchField(text: $query, onSubmit: openSelected,
                                     onMove: moveSelection, onCancel: state.cancelWorkspaceSwitch)
                    .frame(height: 24)
                Button { state.cancelWorkspaceSwitch() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close switcher")
            }
            .padding(18)
            Divider()
            if matches.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "Your workspace is empty" : "No matches",
                    systemImage: query.isEmpty ? "terminal" : "magnifyingglass",
                    description: Text(query.isEmpty ? "Press ⌘T to create a terminal." : "Try a name, agent, folder, canvas, or preset."))
                    .frame(height: 220)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(matches) { item in
                                Button { open(item) } label: { row(item) }
                                    .buttonStyle(.plain)
                                    .id(item.id)
                            }
                        }
                        .padding(8)
                    }
                    .frame(height: 300)
                    .onChange(of: selectedID) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
            Divider()
            HStack {
                Text("↑↓ Navigate     ↵ Open     esc Close")
                Spacer()
                Text(matches.count == 1 ? "1 result" : "\(matches.count) results").monospacedDigit()
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .frame(width: 520)
        .onAppear {
            selectedID = matches.first?.id
        }
        .onChange(of: query) { _, _ in selectedID = results.first?.id }
        .onChange(of: matches.map(\.id)) { _, ids in
            if selectedID.map({ !ids.contains($0) }) ?? true { selectedID = ids.first }
        }
        .onExitCommand { state.cancelWorkspaceSwitch() }
    }

    private func row(_ item: WorkspaceSearch.Item) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.kind == .preset ? "play.circle" : item.kind == .canvas ? "square.grid.2x2" : "terminal")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(item.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if selectedID == item.id {
                Image(systemName: "return").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .hoverHighlight(active: selectedID == item.id)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selectedID == item.id ? .isSelected : [])
    }

    private func moveSelection(by offset: Int) {
        let matches = results
        guard !matches.isEmpty else { return }
        let current = matches.firstIndex { $0.id == selectedID } ?? (offset > 0 ? -1 : matches.count)
        selectedID = matches[min(max(current + offset, 0), matches.count - 1)].id
    }

    private func openSelected() {
        guard let item = results.first(where: { $0.id == selectedID }) else { return }
        open(item)
    }

    private func open(_ item: WorkspaceSearch.Item) {
        state.pendingWorkspaceSwitch = item
        state.switcherShown = false
    }
}

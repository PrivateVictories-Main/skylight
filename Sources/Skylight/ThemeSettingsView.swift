import AppKit
import SwiftUI
import SkylightCore

/// A terminal we know how to read a look out of, and where it keeps it.
/// Named for the migration, not for the format: SkylightCore already owns a
/// `ThemeSource` (which format a theme CAME from) and two types with one name
/// in one module is a coin-flip at every use site.
struct MigrationSource: Identifiable {
    let id: String
    let displayName: String
    /// Absolute paths, first hit wins. `~` already expanded.
    let paths: [String]

    /// The first path that actually exists on this machine, or nil.
    var found: String? {
        paths.first { FileManager.default.fileExists(atPath: $0) }
    }
}

enum ThemeDiscovery {
    private static var home: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// Where the terminals people actually migrate from keep their look.
    /// Ordered by fidelity: the formats that translate exactly come first, so
    /// a machine with several installed offers its best answer at the top.
    static var sources: [MigrationSource] {
        let support = "\(home)/Library/Application Support"
        return [
            MigrationSource(id: "ghostty", displayName: "Ghostty",
                        paths: ["\(home)/.config/ghostty/config"]),
            MigrationSource(id: "iterm2", displayName: "iTerm2",
                        paths: ["\(home)/Library/Preferences/com.googlecode.iterm2.plist"]),
            MigrationSource(id: "warp", displayName: "Warp",
                        paths: ["\(home)/.warp/themes"]),
            MigrationSource(id: "vscode", displayName: "VS Code",
                        paths: ["\(support)/Code/User/settings.json"]),
            MigrationSource(id: "kitty", displayName: "kitty",
                        paths: ["\(home)/.config/kitty/kitty.conf"]),
            MigrationSource(id: "alacritty", displayName: "Alacritty",
                        paths: ["\(home)/.config/alacritty/alacritty.toml",
                                "\(home)/.alacritty.toml"]),
            MigrationSource(id: "wezterm", displayName: "WezTerm",
                        paths: ["\(home)/.config/wezterm/wezterm.lua",
                                "\(home)/.wezterm.lua"]),
        ]
    }

    /// Only the ones that will actually YIELD a theme.
    ///
    /// Existence is not enough, and this is not hypothetical: Ryan's VS Code
    /// settings.json is 391 bytes of `terminal.external.osxExec` and copilot
    /// flags with no colour key anywhere in it — VS Code keeps its look in
    /// `workbench.colorTheme`, a named extension theme, not in colours. A
    /// button that can only ever answer "no themes in file" is exactly the
    /// dead control the harness rows refuse to be.
    ///
    /// So the check is a real parse. The files are small and this runs once
    /// when the tab appears, never per render.
    static func usable() -> [MigrationSource] {
        sources.filter { source in
            guard let path = source.found else { return false }
            if case .success = load(path) { return true }
            return false
        }
    }

    /// A theme file is small. These bounds exist because the walk below runs
    /// on the main actor and the file picker lets someone choose a DIRECTORY —
    /// so "load this folder" could be the home directory, and an unbounded
    /// recursive enumeration of it would hang the app with the Settings window
    /// open.
    private static let maximumDepth = 4
    private static let maximumFilesScanned = 400
    private static let maximumFileBytes = 512 * 1024

    private static let readableExtensions: Set<String> =
        ["yml", "yaml", "itermcolors", "toml", "json", "conf", "config", "lua"]

    /// Read a file at a byte cap. A theme is kilobytes; anything that is not
    /// is not a theme, and reading it whole to find that out is the problem.
    private static func boundedData(at url: URL) -> Data? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= maximumFileBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        return data
    }

    /// Read every theme a path yields.
    ///
    /// Directories are walked to a BOUNDED depth rather than one level: Warp
    /// keeps its themes at `~/.warp/themes/<repo>/themes/*.yml`, three deep,
    /// so a single-level walk would find nothing on the machine this was built
    /// on. Depth, file-count and per-file byte caps give the same protection
    /// without breaking the case that actually exists.
    static func load(_ path: String) -> Result<[SkylightTheme], ThemeImportError> {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        else { return .failure(.empty) }

        if isDirectory.boolValue {
            let root = URL(fileURLWithPath: path)
            let rootDepth = root.standardizedFileURL.pathComponents.count
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { return .failure(.empty) }

            var themes: [SkylightTheme] = []
            var scanned = 0
            for case let url as URL in walker {
                let depth = url.standardizedFileURL.pathComponents.count - rootDepth
                if depth > maximumDepth {
                    walker.skipDescendants()
                    continue
                }
                guard readableExtensions.contains(url.pathExtension.lowercased())
                else { continue }
                scanned += 1
                if scanned > maximumFilesScanned { break }
                guard let data = boundedData(at: url),
                      let parsed = try? ThemeImport.parse(
                        data: data, filename: url.lastPathComponent).get()
                else { continue }
                themes.append(contentsOf: parsed)
            }
            return themes.isEmpty ? .failure(.malformed("no themes in folder"))
                                  : .success(themes)
        }

        guard let data = boundedData(at: URL(fileURLWithPath: path)) else {
            return .failure(.empty)
        }
        let parsed = ThemeImport.parse(data: data,
                                       filename: (path as NSString).lastPathComponent)
        // A ghostty config that only NAMES a theme still counts as an import:
        // resolve the reference against the bundled catalogue.
        if case let .success(themes) = parsed, themes.count == 1,
           let text = String(data: data, encoding: .utf8),
           let config = GhosttyConfigParser.parse(text, name: "config"),
           let reference = config.themeReference ?? config.darkThemeReference,
           let named = ThemeCatalogBridge.resolve(named: reference) {
            // The config's own explicit keys still win over the theme it names
            // — ghostty's rule, and merging is how it is spelled here.
            return .success([named.merging(themes[0])])
        }
        return parsed
    }
}

/// The Theme tab: pick from the bundled catalogue, or bring a look over from
/// whatever terminal you are coming from.
struct ThemeSettingsView: View {
    @State private var query = ""
    @State private var candidates: [SkylightTheme] = []
    @State private var importMessage: String?
    @State private var canRevert = ThemeStore.shared.canRevert
    /// Resolved once when the tab appears — see ThemeDiscovery.usable().
    @State private var migrationSources: [MigrationSource] = []

    private var bundled: [SkylightTheme] {
        let all = ThemeStore.shared.importedThemes + ThemeCatalogBridge.search(query)
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            migrationRow
            Divider().opacity(0.4)
            TextField("Search \(ThemeCatalogBridge.all.count) themes", text: $query)
                .textFieldStyle(.roundedBorder)
            catalogue
            if let importMessage {
                Text(importMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(18)
        .task { migrationSources = ThemeDiscovery.usable() }
        .sheet(isPresented: Binding(get: { !candidates.isEmpty },
                                    set: { if !$0 { candidates = [] } })) {
            ThemeChoiceSheet(themes: candidates) { chosen in
                apply(chosen)
                candidates = []
            }
        }
    }

    // MARK: - Migration

    private var migrationRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Bring your look over")
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(.secondary)
            if migrationSources.isEmpty {
                Text("No other terminal's theme found — use Import File… below.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Only terminals actually installed get a button: a control
                // that cannot do anything is the same lie as a dimmed harness
                // row pretending to be ready.
                FlowRow(items: migrationSources) { source in
                    Button(source.displayName) { load(source) }
                        .buttonStyle(.pressable(scale: 0.97))
                        .font(.system(size: 12))
                }
            }
        }
    }

    // MARK: - Catalogue

    private var catalogue: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(bundled.prefix(200), id: \.name) { theme in
                    Button { apply(theme) } label: {
                        HStack(spacing: 10) {
                            Swatches(theme: theme)
                            Text(theme.name)
                                .font(.system(size: 12.5))
                                .lineLimit(1)
                            Spacer()
                            if isActive(theme) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight(cornerRadius: 8)
                }
            }
        }
        .frame(height: 260)
    }

    private func isActive(_ theme: SkylightTheme) -> Bool {
        ThemeStore.shared.active(isDarkAppearance: ThemeTint.isDarkAppearance)?
            .name == theme.name
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Import File…") { importFile() }
                .buttonStyle(.pressable(scale: 0.97))
                .font(.system(size: 12))
            // Only while there is something to undo. An import WINS over
            // everything set by hand, which is only a fair rule because this
            // is one click away.
            if canRevert {
                Button("Revert to before import") { revert() }
                    .buttonStyle(.pressable(scale: 0.97))
                    .font(.system(size: 12))
            }
            Spacer()
            Button("Use Default") {
                ThemeStore.shared.select(light: nil, dark: nil)
                refresh()
            }
            .buttonStyle(.pressable(scale: 0.97))
            .font(.system(size: 12))
        }
    }

    // MARK: - Actions

    private func load(_ source: MigrationSource) {
        guard let path = source.found else { return }
        switch ThemeDiscovery.load(path) {
        case let .success(themes) where themes.count == 1:
            apply(themes[0])
        case let .success(themes):
            candidates = themes
        case let .failure(error):
            importMessage = describe(error, source: source.displayName)
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a terminal config or theme file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        switch ThemeDiscovery.load(url.path) {
        case let .success(themes) where themes.count == 1: apply(themes[0])
        case let .success(themes): candidates = themes
        case let .failure(error):
            importMessage = describe(error, source: url.lastPathComponent)
        }
    }

    private func apply(_ theme: SkylightTheme) {
        ThemeStore.shared.apply(theme)
        var notes: [String] = []
        if !theme.skipped.isEmpty {
            notes.append("Not imported: \(theme.skipped.joined(separator: ", ")).")
        }
        if let font = ThemeStore.unavailableFont(in: theme) {
            notes.append("\(font) isn't installed — keeping your current font.")
        }
        importMessage = notes.isEmpty
            ? "\(theme.name) applied."
            : "\(theme.name) applied. " + notes.joined(separator: " ")
        refresh()
    }

    private func revert() {
        ThemeStore.shared.revert()
        importMessage = "Reverted to your settings from before the import."
        refresh()
    }

    private func refresh() {
        Appearance.apply(UserDefaults.standard.string(forKey: Appearance.appearanceKey))
        AppState.shared?.sessions.refreshSurfaceTheme()
        AppState.shared?.sessions.refreshSurfaceConfig()
        canRevert = ThemeStore.shared.canRevert
    }

    /// Three failures, three different things to do about them.
    private func describe(_ error: ThemeImportError, source: String) -> String {
        switch error {
        case .empty: "\(source) is empty or unreadable."
        case .unrecognizedFormat: "\(source) isn't a format Skylight can read."
        case let .malformed(reason): "\(source): \(reason)."
        }
    }
}

/// Sixteen-swatch preview: what the theme will actually look like, before
/// committing to it.
private struct Swatches: View {
    let theme: SkylightTheme

    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<8, id: \.self) { index in
                Rectangle()
                    .fill(color(theme.palette[index] ?? theme.foreground))
                    .frame(width: 5, height: 14)
            }
        }
        .background(color(theme.background))
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.12)))
    }

    private func color(_ value: Color8) -> Color {
        Color(nsColor: NSColor(srgbRed: Double(value.r) / 255,
                               green: Double(value.g) / 255,
                               blue: Double(value.b) / 255, alpha: 1))
    }
}

/// One file can hold many themes (a Windows Terminal schemes array, a themes
/// folder). Picking for the user would be guessing.
private struct ThemeChoiceSheet: View {
    let themes: [SkylightTheme]
    let choose: (SkylightTheme) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(themes.count) themes in that file")
                .font(.system(size: 13, weight: .semibold))
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(themes, id: \.name) { theme in
                        Button { choose(theme) } label: {
                            HStack(spacing: 10) {
                                Swatches(theme: theme)
                                Text(theme.name).font(.system(size: 12.5))
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight(cornerRadius: 8)
                    }
                }
            }
            .frame(height: 260)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 380)
    }
}

/// Wrapping row of buttons — the migration chips, however many terminals the
/// machine turns out to have.
private struct FlowRow<Item: Identifiable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 6)],
                  alignment: .leading, spacing: 6) {
            ForEach(items) { content($0) }
        }
    }
}

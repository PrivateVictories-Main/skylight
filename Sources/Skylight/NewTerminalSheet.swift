import AppKit
import SwiftUI
import SkylightCore

/// The tiered New sheet: shell → mode → harness, with the user's most-used
/// combo as a one-click row on top and saved presets one click below it.
/// The engine is always Ghostty — the depth is what runs inside it.
struct NewTerminalSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var shellPath: String?          // nil = login shell
    @State private var agentMode = false
    @State private var harnessID: String?
    @State private var arguments = ""
    @State private var workingDirectory: String?
    @State private var shellsExpanded = false
    @State private var savingPreset = false
    @State private var presetName = ""
    @State private var shells: [Shell] = []
    @State private var installed: [String: String] = [:]   // harness id → binary path
    /// True once install state has been sampled — the one-click rows wait for
    /// it rather than flashing as ready before anything has been checked.
    @State private var loaded = false

    private var spec: TerminalSpec {
        TerminalSpec(
            shellPath: shellPath,
            harness: agentMode ? harnessID : nil,
            arguments: arguments.split(separator: " ").map(String.init),
            workingDirectory: workingDirectory
        )
    }

    private var loginShellName: String {
        Catalog.loginShell(environment: ProcessInfo.processInfo.environment)
            .map { ($0 as NSString).lastPathComponent } ?? "login shell"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let usual = state.usage.topCombo(), loaded {
                recommendationRow(usual)
            }
            if !state.presets.isEmpty, loaded {
                presetRows
            }
            if loaded, state.usage.topCombo() != nil || !state.presets.isEmpty {
                Divider().opacity(0.4)
            }
            shellSection
            Divider().opacity(0.4)
            modeSection
            if agentMode {
                harnessSection
                argumentsRow
            }
            directoryRow
            footer
        }
        .padding(22)
        .frame(width: 460)
        .onAppear(perform: load)
        // First frame from cache (instant); truth arrives a frame later.
        .task { resample() }
        // Closing without launching must not leave a stale spawn target
        // waiting to hijack the next launch. (Launching clears it in launch.)
        .onDisappear { state.pendingSpawn = nil }
        // Come back from a terminal where you just installed a CLI and the
        // row lights up — no reopen needed.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in resample() }
    }

    /// Read-through only: both detections are cached for the app's run, so the
    /// first ⌘T of a session pays for the filesystem and every open after it
    /// is dictionary reads. The sheet's first frame is no longer a stat storm.
    private func load() {
        shells = state.sessions.detectedShells()
        installed = Dictionary(uniqueKeysWithValues: Catalog.harnesses.compactMap { harness in
            state.sessions.cachedResolveHarness(harness.id).map { (harness.id, $0) }
        })
        loaded = true
    }

    /// Returning to the app is the one moment worth re-walking the disk for —
    /// you may have just installed the thing you left to install. Drop the
    /// caches first so this is a genuinely fresh sample, not a replay.
    private func resample() {
        state.sessions.invalidateHarnessCache()
        load()
    }

    private func launch(_ spec: TerminalSpec, name: String? = nil) {
        state.launchFromSheet(spec, name: name)
        dismiss()
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("New Terminal")
                .font(.title3.weight(.semibold))
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.pressable(scale: 0.85))
            .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - Recommendation + presets

    /// One click, straight into the combo you actually use — unless the CLI it
    /// needs has since been uninstalled, in which case it dims and says so.
    private func recommendationRow(_ usual: TerminalSpec) -> some View {
        let ready = isReady(usual)
        return Button { if ready { launch(usual) } } label: {
            HStack(spacing: 10) {
                harnessIcon(for: usual.harness, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Your usual — \(AppState.defaultName(for: usual))")
                        .font(.system(size: 13, weight: .semibold))
                    Text(subtitle(for: usual))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if ready {
                    Text("Start")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text(installCommand(for: usual.harness) ?? "")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .opacity(ready ? 1 : 0.55)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.18))
            )
        }
        .buttonStyle(.pressable(scale: 0.98))
    }

    private var presetRows: some View {
        VStack(spacing: 4) {
            ForEach(state.presets) { preset in
                let ready = isReady(preset.spec)
                Button { if ready { launch(preset.spec, name: preset.name) } } label: {
                    HStack(spacing: 10) {
                        harnessIcon(for: preset.spec.harness, size: 20)
                        Text(preset.name)
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        if ready {
                            Text(subtitle(for: preset.spec))
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        } else {
                            Text(installCommand(for: preset.spec.harness) ?? "")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .opacity(ready ? 1 : 0.55)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .hoverHighlight(cornerRadius: 10)
                .contextMenu {
                    Button("Delete Preset", role: .destructive) {
                        state.deletePreset(preset.id)
                    }
                }
            }
        }
    }

    // MARK: - Shell tier

    private var shellSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    shellsExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("Shell")
                        .font(.system(size: 11, weight: .semibold))
                        .textCase(.uppercase)
                        .kerning(0.6)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(shellPath.map { ($0 as NSString).lastPathComponent }
                        ?? "\(loginShellName) (default)")
                        .font(.system(size: 12, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(shellsExpanded ? 180 : 0))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .hoverHighlight()
            if shellsExpanded {
                shellRow(nil, label: "\(loginShellName) (default)")
                ForEach(shells) { shell in
                    shellRow(shell.path, label: shell.name)
                }
            }
        }
    }

    private func shellRow(_ path: String?, label: String) -> some View {
        Button {
            shellPath = path
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                shellsExpanded = false
            }
        } label: {
            HStack {
                Image(systemName: shellPath == path ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(shellPath == path ? Color.accentColor
                                                       : Color.secondary.opacity(0.4))
                Text(label)
                    .font(.system(size: 12.5))
                Spacer()
                if let path {
                    Text(path)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .hoverHighlight()
    }

    // MARK: - Mode + harness tiers

    private var modeSection: some View {
        HStack {
            Text("Runs")
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(.secondary)
            Spacer()
            SlidingSegments(
                options: [(false, "Terminal"), (true, "Agent CLI")],
                selection: $agentMode
            )
        }
        .padding(.horizontal, 10)
    }

    /// Eight agent CLIs is taller than the sheet should ever be, so the list
    /// scrolls inside a fixed window and the sheet stays compact.
    private var harnessSection: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(Catalog.harnesses) { harness in
                    harnessRow(harness)
                }
            }
        }
        .frame(maxHeight: 292)
    }

    /// Copy sits beside the row button, not inside its label: a Button nested
    /// in another Button's label swallows clicks unpredictably on macOS.
    private func harnessRow(_ harness: Harness) -> some View {
        let path = installed[harness.id]
        return HStack(spacing: 10) {
            Button {
                if path != nil { harnessID = harness.id }
            } label: {
                HStack(spacing: 10) {
                    harnessIcon(for: harness.id, size: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(harness.displayName)
                            .font(.system(size: 13, weight: .semibold))
                        if path == nil {
                            Text(harness.installCommand)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    if path != nil, harnessID == harness.id {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.vertical, 8)
                .padding(.leading, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if path == nil {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(harness.installCommand, forType: .string)
                }
                .buttonStyle(.pressable(scale: 0.94))
                .font(.system(size: 11, weight: .medium))
                .help("Copy the install command")
            }
        }
        .padding(.trailing, 10)
        .opacity(path == nil ? 0.55 : 1)
        .hoverHighlight(cornerRadius: 10, active: harnessID == harness.id)
    }

    private var argumentsRow: some View {
        TextField("Arguments (optional, e.g. --model opus)", text: $arguments)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
    }

    // MARK: - Directory + footer

    private var directoryRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(workingDirectory.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Home")
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK { workingDirectory = panel.url?.path }
            }
            .buttonStyle(.pressable(scale: 0.96))
            .font(.system(size: 11, weight: .medium))
            if workingDirectory != nil {
                Button { workingDirectory = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.pressable(scale: 0.85))
                .help("Reset to Home")
            }
        }
        .padding(.horizontal, 10)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if savingPreset {
                HStack(spacing: 8) {
                    TextField("Preset name", text: $presetName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        // Return in this field saves the preset; it must not
                        // fall through to Create and launch a terminal.
                        .onSubmit { commitPreset() }
                    Button("Save") { commitPreset() }
                    .buttonStyle(.pressable(scale: 0.96))
                    .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            HStack {
                // Canvases don't wait on terminals: an empty app can make one
                // straight from here.
                Button {
                    state.selection = .canvas(state.newCanvas().id)
                    dismiss()
                } label: {
                    Label("New Canvas", systemImage: "square.on.square.dashed")
                }
                .buttonStyle(.pressable(scale: 0.97))
                .font(.system(size: 12))
                .help("Create an empty canvas (⇧⌘N)")
                Button(savingPreset ? "Cancel Preset" : "Save as Preset…") {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        savingPreset.toggle()
                    }
                }
                .buttonStyle(.pressable(scale: 0.97))
                .font(.system(size: 12))
                Spacer()
                Button("Create") { launch(spec) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(agentMode && (harnessID == nil || harnessID.flatMap { installed[$0] } == nil))
            }
        }
    }

    private func commitPreset() {
        let trimmed = presetName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        state.savePreset(named: trimmed, spec: spec)
        presetName = ""
        savingPreset = false
    }

    // MARK: - Shared bits

    @ViewBuilder
    private func harnessIcon(for harnessID: String?, size: CGFloat) -> some View {
        if let brand = harnessID.flatMap({ id in Catalog.harnesses.first { $0.id == id }?.brand }) {
            BrandIcon(brand: brand, size: size)
        } else {
            Image(systemName: "terminal")
                .font(.system(size: size * 0.7, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }

    /// A one-click row is only offered when what it needs is actually there.
    private func isReady(_ spec: TerminalSpec) -> Bool {
        guard let harness = spec.harness else { return true }
        return installed[harness] != nil
    }

    private func installCommand(for harnessID: String?) -> String? {
        harnessID.flatMap { id in Catalog.harnesses.first { $0.id == id }?.installCommand }
    }

    private func subtitle(for spec: TerminalSpec) -> String {
        var parts: [String] = []
        parts.append(spec.shellPath.map { ($0 as NSString).lastPathComponent } ?? loginShellName)
        if !spec.arguments.isEmpty { parts.append(spec.arguments.joined(separator: " ")) }
        if let dir = spec.workingDirectory { parts.append((dir as NSString).lastPathComponent) }
        return parts.joined(separator: " · ")
    }
}

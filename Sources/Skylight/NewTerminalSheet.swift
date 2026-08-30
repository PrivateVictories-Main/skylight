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
    @FocusState private var presetFieldFocused: Bool
    /// The harness whose install command was just copied — brief visual
    /// receipt, then back.
    @State private var copiedHarnessID: String?
    @State private var shells: [Shell] = []
    @State private var harnessEdges = ScrollEdges()
    @State private var harnessViewportHeight: CGFloat = 0
    @State private var installed: [String: String] = [:]   // harness id → binary path
    /// True once install state has been sampled — the one-click rows wait for
    /// it rather than flashing as ready before anything has been checked.
    @State private var loaded = false

    private var spec: TerminalSpec {
        TerminalSpec(
            shellPath: shellPath,
            harness: agentMode ? harnessID : nil,
            // Shell-style splitting: `--dir "/Applications/My Tool"` is one
            // argument, not three mangled ones (SkylightCore.Arguments).
            arguments: Arguments.split(arguments),
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
                autonomyRow
                argumentsRow
            }
            directoryRow
            footer
        }
        .padding(22)
        .frame(width: 460)
        .onAppear {
            load()
            // Consumed, not just read: the debug hook targets ONE opening,
            // and a sticky flag would flip every later sheet in the run.
            if state.debugSheetAgentMode {
                agentMode = true
                state.debugSheetAgentMode = false
            }
        }
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
        // One of the three declared probe triggers — this already fires on
        // didBecomeActive, which is exactly when someone has come back from
        // signing in somewhere else.
        state.refreshSubscriptions()
    }

    private func launch(_ spec: TerminalSpec, name: String? = nil) {
        state.launchFromSheet(spec, name: name)
        dismiss()
    }

    /// The whole interconnect, in one function: run the vendor's OWN login
    /// command in a real Skylight terminal. Skylight holds no credential and
    /// implements no flow — it opens the terminal and gets out of the way.
    private func signIn(_ harness: Harness) {
        guard let spec = SubscriptionCopy.signInSpec(for: harness) else { return }
        state.launchSignIn(spec, harness: harness)
        dismiss()
    }

    private func rowState(_ harness: Harness) -> HarnessRowState {
        HarnessRowState.of(installed: installed[harness.id] != nil,
                           subscription: state.subscriptionState(harness.id))
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
            .help("Close (esc)")
            .accessibilityLabel("Close")
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
                withAnimation(Motion.disclose) {
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
            withAnimation(Motion.disclose) {
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
            Text("Mode")
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

    /// The agent-CLI list is taller than the sheet should ever be, so it
    /// scrolls inside a fixed window and the sheet stays compact.
    ///
    /// The edges fade exactly where content continues — a hard mid-row chop
    /// at the viewport boundary is a sharp edge, and a permanent fade over a
    /// fully-visible first row is a lie. Offset-aware: parked at the top
    /// there is no top fade; scrolled to the end, the bottom one melts away.
    private var harnessSection: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Catalog.harnesses) { harness in
                        harnessRow(harness)
                            .id(harness.id)
                    }
                }
                .background(
                    GeometryReader { geo in
                        let frame = geo.frame(in: .named("harnessScroll"))
                        Color.clear.preference(
                            key: ScrollEdgesKey.self,
                            value: ScrollEdges(top: frame.minY < -1,
                                               bottom: frame.maxY > harnessViewportHeight + 1))
                    }
                )
            }
            // Debug lane only: jump to the end of the list, so screenshot
            // automation can verify the rows below the scroll fold (and the
            // fades trading places) without synthetic scrolling.
            .onAppear {
                guard ProcessInfo.processInfo.environment["SKYLIGHT_SHEET_SCROLL"] == "end",
                      let last = Catalog.harnesses.last else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .coordinateSpace(name: "harnessScroll")
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { harnessViewportHeight = geo.size.height }
                    .onChange(of: geo.size.height) { _, height in
                        harnessViewportHeight = height
                    }
            }
        )
        .onPreferenceChange(ScrollEdgesKey.self) { edges in
            harnessEdges = edges
        }
        .mask(
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: harnessEdges.top ? 20 : 0)
                Rectangle().fill(.black)
                LinearGradient(colors: [.black, .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: harnessEdges.bottom ? 20 : 0)
            }
            .animation(.easeOut(duration: 0.15), value: harnessEdges)
        )
        // Debug lane only: the full list at once, so screenshot automation
        // can verify rows below the scroll fold without synthetic scrolling.
        .frame(maxHeight: ProcessInfo.processInfo
            .environment["SKYLIGHT_SHEET_FULL"] != nil ? .infinity : 292)
    }

    /// Copy sits beside the row button, not inside its label: a Button nested
    /// in another Button's label swallows clicks unpredictably on macOS.
    private func harnessRow(_ harness: Harness) -> some View {
        let path = installed[harness.id]
        let row = rowState(harness)
        let subscription = state.subscriptionState(harness.id)
        return HStack(spacing: 10) {
            Button {
                if row.canLaunch { harnessID = harness.id }
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
                        } else if let detail = SubscriptionCopy.rowDetail(
                            for: harness, state: subscription) {
                            // Installed: say who is signed in, or that nobody
                            // is. Silent for the harnesses we cannot ask.
                            Text(detail)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    if state.probing.contains(harness.id) {
                        ProgressView().controlSize(.small)
                    } else if row == .ready, harnessID == harness.id {
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
            // The third state: installed, and we KNOW it is signed out.
            // Selecting it would only launch a terminal that fails, so the
            // row offers the way in instead.
            if row == .signedOut, SubscriptionCopy.signInSpec(for: harness) != nil {
                Button("Sign in") { signIn(harness) }
                    .buttonStyle(.pressable(scale: 0.94))
                    .font(.system(size: 11, weight: .semibold))
                    .help("Runs this CLI's own login in a Skylight terminal")
            }
            if path == nil {
                // The label is the receipt: silence after a click reads as
                // "did that work?".
                Button(copiedHarnessID == harness.id ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(harness.installCommand, forType: .string)
                    copiedHarnessID = harness.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        if copiedHarnessID == harness.id { copiedHarnessID = nil }
                    }
                }
                .buttonStyle(.pressable(scale: 0.94))
                .font(.system(size: 11, weight: .medium))
                .help("Copy the install command")
            }
        }
        .padding(.trailing, 10)
        .opacity(row == .ready ? 1 : 0.55)
        .hoverHighlight(cornerRadius: 10, active: harnessID == harness.id)
    }

    /// Shown only for the SELECTED harness, and only when we have a verified
    /// flag for it. The copy names that flag outright: this is Ryan choosing,
    /// on his own machine, to let an agent stop asking — a euphemism would be
    /// the one thing that makes it a bad choice.
    @ViewBuilder
    private var autonomyRow: some View {
        if let id = harnessID,
           let harness = Catalog.harness(id),
           let flag = harness.autonomyFlag {
            Toggle(isOn: trustedBinding) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Full autonomy")
                        .font(.system(size: 12.5, weight: .medium))
                    Text("Launches with \(flag) — skips the agent's own permission prompts. Applies to every future \(harness.displayName) terminal.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .padding(.horizontal, 10)
        }
    }

    private var trustedBinding: Binding<Bool> {
        Binding(
            get: { harnessID.map(state.trustedHarnesses.contains) ?? false },
            set: { on in
                guard let id = harnessID else { return }
                state.setTrusted(id, on)
            }
        )
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
                .accessibilityLabel("Reset to Home")
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
                        .focused($presetFieldFocused)
                        // Return in this field saves the preset; it must not
                        // fall through to Create and launch a terminal.
                        .onSubmit { commitPreset() }
                    Button("Save") { commitPreset() }
                    .buttonStyle(.pressable(scale: 0.96))
                    .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            HStack(spacing: 16) {
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
                    withAnimation(Motion.disclose) {
                        savingPreset.toggle()
                    }
                    // Name-it-and-hit-Return is the whole flow; a field that
                    // appears unfocused adds the one click it exists to save.
                    presetFieldFocused = savingPreset
                }
                .buttonStyle(.pressable(scale: 0.97))
                .font(.system(size: 12))
                Spacer()
                Button("Create") { launch(spec) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    // A signed-out harness cannot Create: the terminal would
                    // open and immediately fail with the CLI's own auth error.
                    .disabled(agentMode && !(harnessID
                        .flatMap { Catalog.harness($0) }
                        .map { rowState($0).canLaunch } ?? false))
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
        if let brand = harnessID.flatMap({ Catalog.harness($0)?.brand }) {
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
        guard let id = spec.harness, let harness = Catalog.harness(id) else {
            return spec.harness == nil
        }
        return rowState(harness).canLaunch
    }

    private func installCommand(for harnessID: String?) -> String? {
        harnessID.flatMap { Catalog.harness($0)?.installCommand }
    }

    private func subtitle(for spec: TerminalSpec) -> String {
        var parts: [String] = []
        parts.append(spec.shellPath.map { ($0 as NSString).lastPathComponent } ?? loginShellName)
        if !spec.arguments.isEmpty { parts.append(spec.arguments.joined(separator: " ")) }
        if let dir = spec.workingDirectory { parts.append((dir as NSString).lastPathComponent) }
        return parts.joined(separator: " · ")
    }
}

/// Which edges of the harness list have more content past them — drives the
/// scroll-edge fades above.
private struct ScrollEdges: Equatable, Sendable {
    var top = false
    var bottom = false
}

private struct ScrollEdgesKey: PreferenceKey {
    static let defaultValue = ScrollEdges()
    static func reduce(value: inout ScrollEdges, nextValue: () -> ScrollEdges) {
        let next = nextValue()
        value = ScrollEdges(top: value.top || next.top,
                            bottom: value.bottom || next.bottom)
    }
}

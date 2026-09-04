import SwiftUI
import SkylightCore

/// One preset, with optional complete launch configurations per operating system.
/// Editing never launches a process; Cancel leaves the stored preset untouched.
struct PresetSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LaunchPreset
    @State private var scope = "macos"
    @State private var custom: Bool
    @State private var harness: String
    @State private var shell: String
    @State private var folder: String
    @State private var arguments: String
    private let save: (LaunchPreset) -> Bool

    init(preset: LaunchPreset, save: @escaping (LaunchPreset) -> Bool) {
        self.save = save
        _draft = State(initialValue: preset)
        let spec = preset.resolvedSpec(for: .macos)
        _custom = State(initialValue: preset.platformSpecs?["macos"] != nil)
        _harness = State(initialValue: spec.harness ?? "")
        _shell = State(initialValue: spec.shellPath ?? "")
        _folder = State(initialValue: spec.workingDirectory ?? "")
        _arguments = State(initialValue: Self.quoted(spec.arguments))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Preset").font(.title3.weight(.semibold))
            TextField("Preset name", text: $draft.name)
                .accessibilityLabel("Preset name")
            Picker("Settings for", selection: $scope) {
                Text("Defaults").tag("default")
                Text("macOS").tag("macos")
                Text("Windows").tag("windows")
                Text("Linux").tag("linux")
            }
            if scope != "default" {
                Toggle("Use custom settings", isOn: $custom)
                Text(custom ? "Only this operating system uses these launch settings."
                     : "This operating system uses the preset defaults.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                Picker("Run", selection: $harness) {
                    Text("Shell").tag("")
                    ForEach(Catalog.harnesses, id: \.id) { tool in
                        Text(tool.displayName).tag(tool.id)
                    }
                    if !harness.isEmpty, !Catalog.harnesses.contains(where: { $0.id == harness }) {
                        Text(harness).tag(harness)
                    }
                }
                if harness.isEmpty {
                    TextField("Shell executable (empty uses local default)", text: $shell)
                        .accessibilityLabel("Shell executable")
                }
                TextField("Working folder (empty uses home)", text: $folder)
                    .accessibilityLabel("Working folder")
                TextField("Arguments", text: $arguments)
                    .accessibilityLabel("Arguments")
            }
            .disabled(scope != "default" && !custom)
            Text("Each operating system can use its own shell, CLI, folder, and arguments. Sign-in stays with the CLI on that computer.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Preset") {
                    store(scope)
                    draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if save(draft) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(22)
        .frame(width: 460)
        .onChange(of: custom) { _, enabled in
            if !enabled, scope != "default" {
                let spec = draft.spec
                harness = spec.harness ?? ""
                shell = spec.shellPath ?? ""
                folder = spec.workingDirectory ?? ""
                arguments = Self.quoted(spec.arguments)
            }
        }
        .onChange(of: scope) { old, new in
            store(old)
            load(new)
        }
    }

    private func store(_ key: String) {
        let spec = TerminalSpec(shellPath: shell.isEmpty ? nil : shell,
                                harness: harness.isEmpty ? nil : harness,
                                arguments: Arguments.split(arguments),
                                workingDirectory: folder.isEmpty ? nil : folder)
        if key == "default" { draft.spec = spec }
        else if custom {
            if draft.platformSpecs == nil { draft.platformSpecs = [:] }
            draft.platformSpecs?[key] = spec
        } else { draft.platformSpecs?.removeValue(forKey: key) }
        if draft.platformSpecs?.isEmpty == true { draft.platformSpecs = nil }
    }

    private func load(_ key: String) {
        let spec = draft.platformSpecs?[key] ?? draft.spec
        custom = draft.platformSpecs?[key] != nil
        harness = spec.harness ?? ""
        shell = spec.shellPath ?? ""
        folder = spec.workingDirectory ?? ""
        arguments = Self.quoted(spec.arguments)
    }

    private static func quoted(_ args: [String]) -> String {
        args.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
    }
}

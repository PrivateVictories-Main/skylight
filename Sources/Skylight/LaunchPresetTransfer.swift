import AppKit
import UniformTypeIdentifiers
import SkylightCore

@MainActor
enum LaunchPresetTransfer {
    static func exportPresets(_ state: AppState) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "skylight-presets.json"
        panel.title = "Export Launch Presets"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try LaunchPresetInterchange.encode(state.presets).write(to: url, options: .atomic) }
            catch { NSAlert(error: error).runModal() }
        }
    }

    static func importPresets(_ state: AppState) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.title = "Import Launch Presets"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                guard (values.fileSize ?? 0) <= 4 * 1024 * 1024 else {
                    throw LaunchPresetInterchange.ImportError.tooLarge
                }
                let presets = try LaunchPresetInterchange.decode(Data(contentsOf: url))
                let alert = NSAlert()
                alert.messageText = "Import \(presets.count) launch presets?"
                alert.informativeText = "These presets will be added to the New Terminal launcher. Review their executable, folder, and arguments before launching on this Mac. Importing does not start any sessions."
                alert.addButton(withTitle: "Import Presets")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                for preset in presets { state.savePreset(named: preset.name, spec: preset.spec) }
            } catch { NSAlert(error: error).runModal() }
        }
    }
}

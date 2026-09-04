import Foundation
import GhosttyTerminal

enum BundleVerification {
    /// Runs before AppState is instantiated; no window, daemon, or user state.
    static func run() -> Bool {
        guard Bundle.main.bundleURL.pathExtension == "app",
              let resources = Bundle.main.resourceURL?.resolvingSymlinksInPath(),
              let ghostty = GhosttyRuntimeResources.directoryURL?.resolvingSymlinksInPath(),
              let terminfo = GhosttyRuntimeResources.terminfoDirectoryURL?.resolvingSymlinksInPath(),
              ghostty.path.hasPrefix(resources.path + "/"),
              terminfo.path.hasPrefix(resources.path + "/") else {
            print("Resource verification failed: Ghostty resources must resolve inside this app.")
            return false
        }
        let required = [
            ghostty.appendingPathComponent("shell-integration/zsh/.zshenv"),
            ghostty.appendingPathComponent("shell-integration/bash/ghostty.bash"),
            ghostty.appendingPathComponent("shell-integration/fish/vendor_conf.d/ghostty-shell-integration.fish"),
            terminfo.appendingPathComponent("78/xterm-ghostty"),
        ]
        guard required.allSatisfy({ FileManager.default.isReadableFile(atPath: $0.path) }),
              let executable = Bundle.main.executableURL,
              FileManager.default.isExecutableFile(atPath:
                executable.deletingLastPathComponent().appendingPathComponent("skylightd").path)
        else {
            print("Resource verification failed: shell integration, terminfo, or session keeper is missing.")
            return false
        }
        print("Verified bundled shell integration, terminfo, and session keeper.")
        return true
    }
}

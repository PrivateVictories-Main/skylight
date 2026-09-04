import Darwin
import Foundation

/// Runtime assets required by Ghostty's exec backend.
///
/// The package owns these assets and always points libghostty at this immutable
/// bundle location before the C runtime initializes. User-level Ghostty
/// resources and configuration are never consulted.
public enum GhosttyRuntimeResources {
    /// SwiftPM command-line builds look beside the executable, whereas macOS
    /// app bundles put resources in Contents/Resources. Resolve the app-owned
    /// bundle first so a packaged app never relies on a developer's build tree.
    private static var resourceBundle: Bundle {
        if let resources = Bundle.main.resourceURL,
           let bundle = Bundle(url: resources.appendingPathComponent("GhosttyKit_GhosttyTerminal.bundle")) {
            return bundle
        }
        return Bundle.module
    }

    /// The package-bundled Ghostty resource directory.
    ///
    /// Ghostty expects shell integration below this directory and its compiled
    /// terminfo database in a sibling `terminfo` directory.
    public static var directoryURL: URL? {
        resourceBundle.url(forResource: "Ghostty", withExtension: nil)
    }

    /// The compiled terminfo database exported to child shells by Ghostty.
    public static var terminfoDirectoryURL: URL? {
        resourceBundle.url(forResource: "terminfo", withExtension: nil)
    }

    static func configureEnvironment() {
        guard let path = directoryURL?.path else { return }
        setenv("GHOSTTY_RESOURCES_DIR", path, 1)
    }
}

import Foundation

/// The per-kind defaults, in one place instead of scattered across the app.
/// Dual-mode means the two kinds differ in DEFAULTS, chrome, and affordances —
/// never in runtime — so this is where the "differs" column of that contract
/// actually lives, pure and testable.
public enum KindPolicy {
    /// The name a fresh instance is issued. A harness outranks a shell path
    /// because it is what the terminal RUNS; an uncatalogued harness wears its
    /// own id rather than a placeholder, so a terminal never claims to be a
    /// shell it is not.
    public static func defaultName(for spec: TerminalSpec) -> String {
        switch spec.kind {
        case let .agent(harness):
            return Catalog.harness(harness)?.displayName ?? harness
        case .shell:
            if let shell = spec.shellPath {
                return (shell as NSString).lastPathComponent
            }
            return "Terminal"
        }
    }

    /// Where a new instance starts. The two kinds want different answers: a
    /// shell continues wherever you were working, an agent opens on the last
    /// PROJECT — agents are project-scoped, and dropping one into whatever
    /// directory a stray shell last visited is how you get an agent reasoning
    /// about the wrong repository.
    ///
    /// An empty string is not a directory; it must not beat home.
    public static func defaultWorkingDirectory(for kind: InstanceKind,
                                               home: String,
                                               lastShellDir: String?,
                                               lastProjectDir: String?) -> String {
        func usable(_ path: String?) -> String? {
            guard let path, !path.isEmpty else { return nil }
            return path
        }
        switch kind {
        case .shell: return usable(lastShellDir) ?? home
        case .agent: return usable(lastProjectDir) ?? home
        }
    }
}

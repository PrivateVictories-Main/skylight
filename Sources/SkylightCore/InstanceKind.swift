import CoreGraphics
import Foundation

/// What a terminal instance IS, named once instead of re-derived at every call
/// site. Skylight is dual-mode on purpose: a regular terminal and an agent-CLI
/// terminal are both first-class, and they differ in defaults, chrome, and
/// affordances — never in runtime. An agent instance is a terminal instance
/// that happens to run an agent: same pty, same keeper, same survival, same
/// canvas, same theme.
public enum InstanceKind: Equatable, Hashable, Sendable {
    case shell
    case agent(harness: String)

    /// The harness id when this is an agent; nil for a shell. The inverse of
    /// the derivation below, for call sites that still want the raw id.
    public var harnessID: String? {
        switch self {
        case .shell: nil
        case let .agent(harness): harness
        }
    }

    public var isAgent: Bool { harnessID != nil }
}

public extension TerminalSpec {
    /// DERIVED, never stored. `harness` remains the single source of truth, so
    /// there is no second copy to drift, nothing new on disk, and no
    /// migration — exactly the discipline `Residency` uses for board
    /// membership. A stored kind and a stored harness are one edit away from
    /// disagreeing, and the sidebar would believe the wrong one.
    var kind: InstanceKind {
        harness.map { .agent(harness: $0) } ?? .shell
    }
}

/// When the terminal-aimed menu commands (clear, find, prompt jumping) may
/// actually do something.
///
/// Pure and pinned because the alternative is a menu item that looks live and
/// silently does nothing — the exact lie the zoom menu's own comments already
/// forbid. It shares the canvas's honest-zoom contract: at anything other
/// than exactly 100% a tile is an overview thumbnail, not a surface you can
/// type into, so a command aimed at one would go nowhere.
public enum TerminalCommands {
    public static func available(hasTerminal: Bool, focused: Bool,
                                 zoom: CGFloat) -> Bool {
        guard hasTerminal else { return false }
        // Focus mode fills the window: no canvas transform applies.
        if focused { return true }
        return zoom == 1
    }
}

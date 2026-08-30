import Foundation

/// What the session keeper actually runs — the one decision that turns a
/// spec into an argv. Pure so the fallback chain is provable: a missing
/// harness falls back to the chosen shell, a vanished shell to the login
/// shell, a broken login shell to /bin/zsh. Terminals always exist; the
/// banner tells the truth about what they run.
public enum Launch {
    public static func argv(shellPath: String?,
                            harnessBinary: String?,
                            harnessArguments: [String],
                            isExecutable: (String) -> Bool,
                            loginShell: String?) -> [String] {
        if let harnessBinary {
            return [harnessBinary] + harnessArguments
        }
        if let shellPath, isExecutable(shellPath) {
            return [shellPath, "-l"]
        }
        let fallback = loginShell.flatMap { isExecutable($0) ? $0 : nil } ?? "/bin/zsh"
        return [fallback, "-l"]
    }
}

public extension Launch {
    /// The environment additions that switch ghostty's shell integration on
    /// for a session.
    ///
    /// This is what makes the REGULAR terminal first-class. Without the
    /// integration the engine never learns the working directory (OSC 7),
    /// never marks prompts (OSC 133) and never reports a finished command —
    /// so cwd in a tile header, "new terminal here", prompt jumping and the
    /// duration badge are not features that were skipped, they are features
    /// that were impossible.
    ///
    /// Returns ADDITIONS only. The daemon merges these over the inherited
    /// environment, so a key emitted here wins and a key left out leaves the
    /// user's own value untouched. TERM is deliberately not among them — that
    /// belongs to the daemon, which has always set it.
    ///
    /// Pure, so the whole decision is testable without spawning anything.
    static func environment(kind: InstanceKind,
                            shellPath: String?,
                            resourcesPath: String?,
                            base: [String: String]) -> [String: String] {
        // An agent terminal runs a BINARY, not a login shell. Pointing ZDOTDIR
        // at our bundle for a process that never reads it is noise, and it
        // would leak into whatever subshell the agent spawns.
        guard case .shell = kind, let resourcesPath else { return [:] }

        var result = ["GHOSTTY_RESOURCES_DIR": resourcesPath]
        // Conservative on purpose. `title` and `cursor` are cosmetic and
        // wanted — the sidebar's activity caption reads the title. `path`,
        // `sudo` and the `ssh-*` features rewrite PATH, wrap sudo, and change
        // how ssh forwards the environment; none of that is something a
        // terminal should switch on for somebody without being asked.
        result["GHOSTTY_SHELL_FEATURES"] = "title,cursor"

        let integration = resourcesPath + "/shell-integration"
        let shell = shellPath ?? base["SHELL"] ?? ""
        switch (shell as NSString).lastPathComponent {
        case "zsh":
            // zsh is injected by pointing ZDOTDIR at the bundled directory;
            // its `.zshenv` restores the user's own from GHOSTTY_ZSH_ZDOTDIR
            // and then sources their real config. Dropping that variable
            // silently discards somebody's entire zsh setup — and the script
            // distinguishes "restore this" from "unset it" by whether the
            // variable exists at all, so an absent one must stay absent.
            result["ZDOTDIR"] = integration + "/zsh"
            if let existing = base["ZDOTDIR"] {
                result["GHOSTTY_ZSH_ZDOTDIR"] = existing
            }
        case "fish":
            // fish finds `vendor_conf.d` through XDG_DATA_DIRS. PREPENDED,
            // never replaced: clobbering it would hide every other vendor's
            // fish files on the machine.
            let existing = base["XDG_DATA_DIRS"]
            result["XDG_DATA_DIRS"] = existing.map { "\(integration):\($0)" }
                ?? integration
        default:
            // bash needs its startup ARGV changed (`--posix` alongside
            // BASH_ENV), which an environment dictionary cannot do. Half the
            // mechanism is worse than none: BASH_ENV on its own changes what a
            // non-interactive bash sources and buys nothing. Same for the
            // shells with no bundled integration. They still get
            // GHOSTTY_RESOURCES_DIR, which is harmless and lets a hand-written
            // rc file opt in.
            break
        }
        return result
    }
}

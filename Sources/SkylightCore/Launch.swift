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

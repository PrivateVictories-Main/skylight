import Foundation

public struct Shell: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public var name: String { (path as NSString).lastPathComponent }

    public init(path: String) { self.path = path }
}

public struct Harness: Identifiable, Equatable, Sendable {
    public let id: String            // the binary name, e.g. "claude"
    public let displayName: String
    public let installCommand: String
    public let brand: Brand?         // nil = no official vector mark; UI uses a glyph
    /// The flag that makes this CLI stop asking permission for its own
    /// actions, or nil when we have not VERIFIED one from its live `--help`.
    /// nil is not "no such flag exists" — it is "we will not guess". A guessed
    /// flag either fails the launch or grants something other than what the
    /// toggle promised, so an unverified harness simply shows no toggle.
    public let autonomyFlag: String?
    /// How to ask this CLI whether it is signed in, and how to sign in. nil =
    /// we have not verified anything, and will not guess. See AuthProbe.
    public let authProbe: AuthProbe?

    public init(id: String, displayName: String, installCommand: String, brand: Brand?,
                autonomyFlag: String? = nil, authProbe: AuthProbe? = nil) {
        self.id = id
        self.displayName = displayName
        self.installCommand = installCommand
        self.brand = brand
        self.autonomyFlag = autonomyFlag
        self.authProbe = authProbe
    }
}

public enum Catalog {
    /// The agent CLIs the New sheet offers. Install state is detected live;
    /// an uninstalled harness renders dimmed with its install command.
    public static let harnesses: [Harness] = [
        // Probes below are VERIFIED against the live CLIs on 2026-08-30. An
        // unverified harness gets no probe at all; see the cursor-agent note.
        Harness(id: "claude", displayName: "Claude Code",
                installCommand: "npm i -g @anthropic-ai/claude-code", brand: .claudeCode,
                autonomyFlag: "--dangerously-skip-permissions",
                // `claude auth status` prints JSON and exits 0:
                // {"loggedIn": true, "authMethod": "claude.ai",
                //  "email": "…", "subscriptionType": "max", …}
                // Read by KEY, not by pattern — the spacing of a serialization
                // is not a contract, the field names are.
                authProbe: AuthProbe(
                    statusCommand: ["auth", "status"],
                    format: .json(loggedInKey: "loggedIn",
                                  accountKey: "email",
                                  planKey: "subscriptionType"),
                    credentialMarkers: ["~/.claude.json"],
                    loginCommand: ["auth", "login"])),
        Harness(id: "codex", displayName: "Codex",
                installCommand: "npm i -g @openai/codex", brand: .openai,
                autonomyFlag: "--dangerously-bypass-approvals-and-sandbox",
                // `codex login status` prints one line: "Logged in using ChatGPT".
                authProbe: AuthProbe(
                    statusCommand: ["login", "status"],
                    format: .text(signedIn: ["Logged in using"],
                                  signedOut: ["Not logged in", "not logged in"]),
                    credentialMarkers: ["~/.codex/auth.json"],
                    loginCommand: ["login"])),
        Harness(id: "gemini", displayName: "Gemini CLI",
                installCommand: "npm i -g @google/gemini-cli", brand: .gemini,
                autonomyFlag: "--yolo",
                // Not installed here, so nothing could be verified: markers
                // only, from its documented credential path.
                authProbe: AuthProbe(
                    credentialMarkers: ["~/.gemini/oauth_creds.json"],
                    loginCommand: [])),
        Harness(id: "copilot", displayName: "Copilot CLI",
                installCommand: "npm i -g @github/copilot", brand: .copilot,
                autonomyFlag: "--allow-all-tools"),
        Harness(id: "cursor-agent", displayName: "Cursor CLI",
                installCommand: "curl https://cursor.com/install -fsS | bash", brand: .cursor,
                autonomyFlag: "--force",
                // NO status command, and this is the important one.
                //
                // `cursor-agent status` LOOKS like the read-only probe every
                // other CLI has. Run on 2026-08-30 it printed "Starting login
                // process… Authenticating with Cursor…" and hung until it was
                // killed. A guessed probe would not merely fail here — it
                // would hijack the app into an interactive login nobody asked
                // for, on a background queue, with a timeout as the only way
                // out. This is what "nil means we will not guess" is for.
                authProbe: AuthProbe(
                    credentialMarkers: ["~/.cursor"],
                    loginCommand: ["login"])),
        Harness(id: "qwen", displayName: "Qwen Code",
                installCommand: "npm i -g @qwen-code/qwen-code", brand: .qwen),
        Harness(id: "amp", displayName: "Amp",
                installCommand: "npm i -g @sourcegraph/amp", brand: .amp),
        Harness(id: "opencode", displayName: "OpenCode",
                installCommand: "npm i -g opencode-ai", brand: .opencode,
                autonomyFlag: "--auto",
                // `opencode auth list` was not verified (the run was killed
                // alongside the cursor-agent hang), so no status command —
                // markers and a login only.
                authProbe: AuthProbe(
                    credentialMarkers: ["~/.local/share/opencode/auth.json"],
                    loginCommand: ["auth", "login"])),
        // The 2026 wave — real adoption, official CLIs, no official vector
        // marks yet (brand nil = glyph, per the never-fake-a-mark rule).
        // Autonomy flags stay nil until verified from live --help: droid's
        // documented `--auto <level>` takes a value, which the single-word
        // flag contract here cannot carry honestly.
        Harness(id: "droid", displayName: "Droid",
                installCommand: "curl -fsSL https://app.factory.ai/cli | sh", brand: nil),
        Harness(id: "goose", displayName: "Goose",
                installCommand: "curl -fsSL https://github.com/aaif-goose/goose/releases/download/stable/download_cli.sh | bash",
                brand: nil),
        Harness(id: "crush", displayName: "Crush",
                installCommand: "npm i -g @charmland/crush", brand: nil),
    ]

    /// The catalogued harness for a binary id, or nil for one we do not know.
    /// ONE lookup: this exact `first { $0.id == id }` was written out at six
    /// call sites across three files, which is six places for a future
    /// catalogue change to be half-applied.
    public static func harness(_ id: String) -> Harness? {
        harnesses.first { $0.id == id }
    }

    /// The same lookup addressed by instance kind — a shell has no harness,
    /// and saying so here keeps the `if let harness` dance out of the views.
    public static func harness(for kind: InstanceKind) -> Harness? {
        kind.harnessID.flatMap(harness)
    }

    /// /etc/shells → shell paths, comments and blank lines stripped.
    public static func parseShellsFile(_ contents: String) -> [String] {
        contents.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Installed shells, one per name (first path listed wins).
    public static func installedShells(fromShellsFile contents: String,
                                       isExecutable: (String) -> Bool) -> [Shell] {
        var seen = Set<String>()
        return parseShellsFile(contents)
            .filter { isExecutable($0) && seen.insert(($0 as NSString).lastPathComponent).inserted }
            .map(Shell.init)
    }

    /// The user's login shell from the environment; nil when unset.
    public static func loginShell(environment: [String: String]) -> String? {
        environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Resolve a binary name against PATH plus the usual user-install dirs.
    public static func resolve(_ name: String, pathVariable: String?, home: String,
                               isExecutable: (String) -> Bool) -> String? {
        var dirs = (pathVariable ?? "").split(separator: ":").map(String.init)
        dirs += ["\(home)/.local/bin", "/usr/local/bin", "/opt/homebrew/bin"]
        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
            .map { "\($0)/\(name)" }
            .first(where: isExecutable)
    }
}

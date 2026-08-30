import XCTest
import SkylightCore

/// Shell integration is what makes the REGULAR terminal first-class: without
/// it the engine never learns the working directory, never marks prompts, and
/// never reports a finished command — so cwd in the header, "new terminal
/// here", prompt jumping and the duration badge are all impossible.
///
/// The daemon lane has always passed `SpawnRequest.env` through to the child;
/// the app simply never filled it.
final class ShellIntegrationTests: XCTestCase {
    private let resources = "/Bundle/Ghostty"

    private func env(for shell: String?, base: [String: String] = [:],
                     kind: InstanceKind = .shell) -> [String: String] {
        Launch.environment(kind: kind, shellPath: shell,
                           resourcesPath: resources, base: base)
    }

    func testZshGetsZDOTDIRPointedAtTheBundledIntegration() {
        let result = env(for: "/bin/zsh")
        XCTAssertEqual(result["ZDOTDIR"],
                       "/Bundle/Ghostty/shell-integration/zsh")
        XCTAssertEqual(result["GHOSTTY_RESOURCES_DIR"], resources)
    }

    /// The bundled `.zshenv` restores the user's own ZDOTDIR from this
    /// variable and then sources their real config. Losing it means silently
    /// dropping somebody's entire zsh setup.
    func testTheUsersOwnZDOTDIRIsPreservedForRestoration() {
        let result = env(for: "/bin/zsh", base: ["ZDOTDIR": "/Users/x/.config/zsh"])
        XCTAssertEqual(result["GHOSTTY_ZSH_ZDOTDIR"], "/Users/x/.config/zsh")
        XCTAssertEqual(result["ZDOTDIR"], "/Bundle/Ghostty/shell-integration/zsh")
    }

    /// If they had none, we must not invent one — the integration's `.zshenv`
    /// distinguishes "restore this" from "unset it" by whether the variable
    /// is set at all.
    func testNoUserZDOTDIRMeansNoRestorationVariable() {
        XCTAssertNil(env(for: "/bin/zsh")["GHOSTTY_ZSH_ZDOTDIR"])
    }

    func testFishGetsXDGDataDirsWithTheBundleFirst() {
        let result = env(for: "/opt/homebrew/bin/fish")
        let dirs = try? XCTUnwrap(result["XDG_DATA_DIRS"])
        XCTAssertTrue(dirs?.hasPrefix("/Bundle/Ghostty/shell-integration") ?? false,
                      "got \(dirs ?? "nil")")
    }

    /// Prepended, never replaced: clobbering XDG_DATA_DIRS would hide every
    /// other vendor's fish completions on the machine.
    func testFishKeepsAnExistingXDGDataDirs() {
        let result = env(for: "/usr/local/bin/fish",
                         base: ["XDG_DATA_DIRS": "/opt/share:/usr/share"])
        XCTAssertEqual(result["XDG_DATA_DIRS"],
                       "/Bundle/Ghostty/shell-integration:/opt/share:/usr/share")
    }

    /// bash needs its startup ARGV changed (`--posix` plus BASH_ENV), which is
    /// not something an environment dictionary can do. Injecting half of the
    /// mechanism would be worse than none: BASH_ENV alone changes what a
    /// non-interactive bash sources, for no benefit.
    func testBashGetsNoIntegrationRatherThanHalfOfIt() {
        let result = env(for: "/bin/bash")
        XCTAssertNil(result["BASH_ENV"])
        XCTAssertNil(result["ZDOTDIR"])
        // It still gets the resources dir; that is harmless and lets a
        // hand-written bashrc opt in.
        XCTAssertEqual(result["GHOSTTY_RESOURCES_DIR"], resources)
    }

    /// An AGENT terminal runs a binary, not a login shell. Pointing ZDOTDIR at
    /// our bundle for a process that never reads it is noise at best, and at
    /// worst leaks into whatever subshell the agent spawns.
    func testAgentTerminalsGetNoShellInjection() {
        let result = env(for: nil, kind: .agent(harness: "claude"))
        XCTAssertNil(result["ZDOTDIR"])
        XCTAssertNil(result["XDG_DATA_DIRS"])
    }

    func testNilShellPathIsTreatedAsTheLoginShell() {
        // A spec with no shell runs $SHELL; the integration has to follow it.
        let result = Launch.environment(kind: .shell, shellPath: nil,
                                        resourcesPath: resources,
                                        base: ["SHELL": "/bin/zsh"])
        XCTAssertEqual(result["ZDOTDIR"], "/Bundle/Ghostty/shell-integration/zsh")
    }

    func testNoResourcesPathMeansNoInjectionAtAll() {
        // A build with no bundled resources must not point the shell at a
        // directory that does not exist.
        let result = Launch.environment(kind: .shell, shellPath: "/bin/zsh",
                                        resourcesPath: nil, base: [:])
        XCTAssertTrue(result.isEmpty)
    }

    /// The features list is conservative on purpose — see the implementation.
    func testFeaturesEnableTitleAndCursorOnly() {
        let features = env(for: "/bin/zsh")["GHOSTTY_SHELL_FEATURES"]
        XCTAssertEqual(features, "title,cursor")
    }

    /// We add to the environment; we never subtract from it. The daemon merges
    /// this over the inherited environment, so a key we emit wins — and one we
    /// do not emit leaves the user's own value alone.
    func testNothingUnrelatedIsEmitted() {
        let result = env(for: "/bin/zsh", base: ["PATH": "/usr/bin", "EDITOR": "vim"])
        XCTAssertNil(result["PATH"])
        XCTAssertNil(result["EDITOR"])
        XCTAssertNil(result["TERM"], "TERM belongs to the daemon, not here")
    }
}

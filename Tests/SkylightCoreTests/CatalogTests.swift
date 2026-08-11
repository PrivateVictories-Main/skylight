import XCTest
import SkylightCore

final class CatalogTests: XCTestCase {
    func testParseShellsFileStripsCommentsAndBlanks() {
        let contents = """
        # /etc/shells
        # comment

        /bin/zsh
        /bin/bash
          /bin/dash
        """
        XCTAssertEqual(Catalog.parseShellsFile(contents), ["/bin/zsh", "/bin/bash", "/bin/dash"])
    }

    func testInstalledShellsFiltersAndDedupesByName() {
        let contents = "/bin/zsh\n/usr/local/bin/zsh\n/bin/bash\n/opt/fish/bin/fish\n"
        let installed = Catalog.installedShells(fromShellsFile: contents,
                                                isExecutable: { $0 != "/opt/fish/bin/fish" })
        XCTAssertEqual(installed.map(\.path), ["/bin/zsh", "/bin/bash"])   // dup zsh + missing fish dropped
        XCTAssertEqual(installed.map(\.name), ["zsh", "bash"])
    }

    func testLoginShell() {
        XCTAssertEqual(Catalog.loginShell(environment: ["SHELL": "/bin/zsh"]), "/bin/zsh")
        XCTAssertNil(Catalog.loginShell(environment: ["SHELL": ""]))
        XCTAssertNil(Catalog.loginShell(environment: [:]))
    }

    func testResolveSearchesPathThenFallbacks() {
        let exists = ["/opt/homebrew/bin/claude", "/custom/bin/codex"]
        XCTAssertEqual(
            Catalog.resolve("codex", pathVariable: "/custom/bin:/usr/bin",
                            home: "/Users/x", isExecutable: { exists.contains($0) }),
            "/custom/bin/codex")
        XCTAssertEqual(
            Catalog.resolve("claude", pathVariable: "/usr/bin",
                            home: "/Users/x", isExecutable: { exists.contains($0) }),
            "/opt/homebrew/bin/claude")                                   // fallback dir
        XCTAssertNil(
            Catalog.resolve("gemini", pathVariable: nil,
                            home: "/Users/x", isExecutable: { exists.contains($0) }))
    }

    func testHarnessCatalogShape() {
        XCTAssertEqual(Catalog.harnesses.map(\.id),
                       ["claude", "codex", "gemini", "copilot", "cursor-agent",
                        "qwen", "amp", "opencode"])
        XCTAssertEqual(Catalog.harnesses.map(\.brand),
                       [.claudeCode, .openai, .gemini, .copilot, .cursor,
                        .qwen, .amp, .opencode])
        XCTAssertEqual(Catalog.harnesses.first?.brand, .claudeCode)
        // Install commands are user-visible promises — pin them all.
        XCTAssertEqual(Catalog.harnesses.map(\.installCommand), [
            "npm i -g @anthropic-ai/claude-code",
            "npm i -g @openai/codex",
            "npm i -g @google/gemini-cli",
            "npm i -g @github/copilot",
            "curl https://cursor.com/install -fsS | bash",
            "npm i -g @qwen-code/qwen-code",
            "npm i -g @sourcegraph/amp",
            "npm i -g opencode-ai",
        ])
        XCTAssertTrue(Catalog.harnesses.allSatisfy { $0.brand != nil })
        // Autonomy flags are typed straight onto a command line on Ryan's
        // machine — pin all eight, nils included. A nil here means "not
        // verified from live --help output", and inventing one would either
        // break the launch or grant something the toggle never promised.
        XCTAssertEqual(Catalog.harnesses.map(\.autonomyFlag), [
            "--dangerously-skip-permissions",              // claude
            "--dangerously-bypass-approvals-and-sandbox",  // codex
            nil,                                           // gemini
            nil,                                           // copilot
            nil,                                           // cursor-agent
            nil,                                           // qwen
            nil,                                           // amp
            "--auto",                                      // opencode
        ])
        // No flag may carry whitespace: they are prepended into ghostty's
        // word-split command line, where a space would silently become a
        // second argument.
        XCTAssertTrue(Catalog.harnesses.compactMap(\.autonomyFlag)
            .allSatisfy { !$0.contains(" ") && $0.hasPrefix("--") })
    }
}

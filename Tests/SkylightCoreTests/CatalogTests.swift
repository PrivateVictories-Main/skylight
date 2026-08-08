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
        XCTAssertEqual(Catalog.harnesses.map(\.id), ["claude", "codex", "gemini", "opencode"])
        XCTAssertEqual(Catalog.harnesses.first?.brand, .claude)
        XCTAssertNil(Catalog.harnesses.last?.brand)                       // opencode: no official mark
    }
}

import XCTest
import SkylightCore

final class LaunchTests: XCTestCase {
    func testHarnessBinaryWinsOutright() {
        XCTAssertEqual(
            Launch.argv(shellPath: "/bin/fish", harnessBinary: "/opt/bin/claude",
                        harnessArguments: ["--dangerously-skip-permissions", "--model", "opus"],
                        isExecutable: { _ in true }, loginShell: "/bin/zsh"),
            ["/opt/bin/claude", "--dangerously-skip-permissions", "--model", "opus"])
    }

    func testChosenShellRunsAsLoginShell() {
        XCTAssertEqual(
            Launch.argv(shellPath: "/bin/fish", harnessBinary: nil, harnessArguments: [],
                        isExecutable: { $0 == "/bin/fish" }, loginShell: "/bin/zsh"),
            ["/bin/fish", "-l"])
    }

    func testVanishedShellFallsBackToLoginShell() {
        XCTAssertEqual(
            Launch.argv(shellPath: "/gone/fish", harnessBinary: nil, harnessArguments: [],
                        isExecutable: { $0 == "/bin/zsh" }, loginShell: "/bin/zsh"),
            ["/bin/zsh", "-l"])
    }

    func testBrokenLoginShellFallsBackToZsh() {
        // SHELL points somewhere unexecutable (or nowhere): the terminal
        // still exists — /bin/zsh is the floor.
        XCTAssertEqual(
            Launch.argv(shellPath: nil, harnessBinary: nil, harnessArguments: [],
                        isExecutable: { _ in false }, loginShell: "/gone/zsh"),
            ["/bin/zsh", "-l"])
        XCTAssertEqual(
            Launch.argv(shellPath: nil, harnessBinary: nil, harnessArguments: [],
                        isExecutable: { _ in false }, loginShell: nil),
            ["/bin/zsh", "-l"])
    }

    func testMissingHarnessFallsThroughTheWholeChain() {
        // Harness unresolved (binary nil): the chosen shell carries the
        // session, exactly what the banner promises.
        XCTAssertEqual(
            Launch.argv(shellPath: "/bin/bash", harnessBinary: nil,
                        harnessArguments: ["ignored"],
                        isExecutable: { $0 == "/bin/bash" }, loginShell: "/bin/zsh"),
            ["/bin/bash", "-l"])
    }
}

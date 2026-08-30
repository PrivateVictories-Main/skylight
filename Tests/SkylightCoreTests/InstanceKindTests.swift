import XCTest
import SkylightCore

final class InstanceKindTests: XCTestCase {
    func testKindIsShellWhenNoHarness() {
        XCTAssertEqual(TerminalSpec().kind, .shell)
        XCTAssertEqual(TerminalSpec(shellPath: "/bin/zsh").kind, .shell)
    }

    func testKindIsAgentWithHarnessID() {
        XCTAssertEqual(TerminalSpec(harness: "claude").kind, .agent(harness: "claude"))
        XCTAssertEqual(TerminalSpec(shellPath: "/bin/fish", harness: "codex").kind,
                       .agent(harness: "codex"))
    }

    /// The kind is DERIVED, never stored: a spec that round-trips through JSON
    /// must come back with the same kind and no extra key. A stored copy is how
    /// the sidebar drifts out of sync with the truth — the same reason
    /// `Residency` derives board membership instead of keeping it.
    func testKindRoundTripsThroughSpecEncodingWithoutBeingStored() throws {
        let spec = TerminalSpec(shellPath: "/bin/zsh", harness: "gemini",
                                arguments: ["--yolo"], workingDirectory: "/tmp")
        let data = try JSONEncoder().encode(spec)
        let decoded = try JSONDecoder().decode(TerminalSpec.self, from: data)
        XCTAssertEqual(decoded.kind, spec.kind)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["kind"], "kind must be derived, never written to disk")
    }

    func testKindIgnoresArgumentsAndWorkingDirectory() {
        let a = TerminalSpec(harness: "claude", arguments: ["--model", "opus"])
        let b = TerminalSpec(harness: "claude", workingDirectory: "/tmp")
        XCTAssertEqual(a.kind, b.kind)
        XCTAssertEqual(a.kind, .agent(harness: "claude"))
    }

    func testKindIsHashableSoItCanKeyPolicyTables() {
        let set: Set<InstanceKind> = [.shell, .agent(harness: "claude"),
                                      .agent(harness: "claude"), .agent(harness: "codex")]
        XCTAssertEqual(set.count, 3)
    }
}

final class KindPolicyTests: XCTestCase {
    /// Pins the EXACT strings AppState.defaultName produces today. This is the
    /// behavior contract the move into SkylightCore must not bend: a shell
    /// names itself after its shell, an agent after its display name, and an
    /// unknown harness after its own id rather than a placeholder.
    func testDefaultNameMatchesLegacyBehaviourForShellAndAgent() {
        XCTAssertEqual(KindPolicy.defaultName(for: TerminalSpec()), "Terminal")
        XCTAssertEqual(KindPolicy.defaultName(for: TerminalSpec(shellPath: "/bin/fish")),
                       "fish")
        XCTAssertEqual(KindPolicy.defaultName(for: TerminalSpec(harness: "claude")),
                       "Claude Code")
        XCTAssertEqual(KindPolicy.defaultName(for: TerminalSpec(harness: "cursor-agent")),
                       "Cursor CLI")
        // Unknown harness: its own id, never "Terminal" — the name must not
        // quietly claim to be a shell.
        XCTAssertEqual(KindPolicy.defaultName(for: TerminalSpec(harness: "mystery")),
                       "mystery")
        // A harness outranks a shell path: that is what the terminal RUNS.
        XCTAssertEqual(
            KindPolicy.defaultName(for: TerminalSpec(shellPath: "/bin/fish",
                                                     harness: "codex")),
            "Codex")
    }

    func testShellCwdPrefersLastShellDir() {
        XCTAssertEqual(
            KindPolicy.defaultWorkingDirectory(for: .shell, home: "/Users/x",
                                               lastShellDir: "/tmp/work",
                                               lastProjectDir: "/code/proj"),
            "/tmp/work")
    }

    func testAgentCwdPrefersLastProjectDir() {
        // Agents are project-scoped: the last PROJECT wins, not wherever a
        // shell happened to be.
        XCTAssertEqual(
            KindPolicy.defaultWorkingDirectory(for: .agent(harness: "claude"),
                                               home: "/Users/x",
                                               lastShellDir: "/tmp/work",
                                               lastProjectDir: "/code/proj"),
            "/code/proj")
    }

    func testBothFallBackToHome() {
        for kind: InstanceKind in [.shell, .agent(harness: "claude")] {
            XCTAssertEqual(
                KindPolicy.defaultWorkingDirectory(for: kind, home: "/Users/x",
                                                   lastShellDir: nil,
                                                   lastProjectDir: nil),
                "/Users/x", "\(kind)")
        }
        // An empty string is not a directory — it must not beat home.
        XCTAssertEqual(
            KindPolicy.defaultWorkingDirectory(for: .shell, home: "/Users/x",
                                               lastShellDir: "", lastProjectDir: ""),
            "/Users/x")
    }
}

/// Menu items that silently do nothing are the exact lie the zoom menu's own
/// comments forbid — so the enablement rule is pure and pinned.
final class TerminalCommandAvailabilityTests: XCTestCase {
    func testUnavailableWithNothingSelected() {
        XCTAssertFalse(TerminalCommands.available(hasTerminal: false,
                                                  focused: false, zoom: 1))
    }

    func testAvailableForAFullWindowTerminal() {
        XCTAssertTrue(TerminalCommands.available(hasTerminal: true,
                                                 focused: false, zoom: 1))
    }

    func testAvailableInFocusMode() {
        XCTAssertTrue(TerminalCommands.available(hasTerminal: true,
                                                 focused: true, zoom: 0.5))
    }

    /// At overview zoom no tile is typable — the canvas says so, and a Find
    /// or Clear aimed at a surface you cannot type into would go nowhere.
    func testUnavailableAtOverviewZoomOnACanvas() {
        XCTAssertFalse(TerminalCommands.available(hasTerminal: true,
                                                  focused: false, zoom: 0.5))
        XCTAssertFalse(TerminalCommands.available(hasTerminal: true,
                                                  focused: false, zoom: 1.5))
    }

    func testAvailableAtExactlyOneHundredPercent() {
        XCTAssertTrue(TerminalCommands.available(hasTerminal: true,
                                                 focused: false, zoom: 1))
    }
}

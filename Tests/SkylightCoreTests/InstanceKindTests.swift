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

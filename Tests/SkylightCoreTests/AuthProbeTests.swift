import XCTest
import SkylightCore

/// No test here runs a CLI or opens a credential file. Every one of them
/// evaluates captured output — which is the same discipline the feature
/// itself follows.
final class AuthProbeTests: XCTestCase {
    // MARK: - Declarations

    func testUnverifiedHarnessHasNoProbe() {
        // Same contract as autonomyFlag: nil means "we have not verified one",
        // never "none exists". A guessed status command is worse than none —
        // see the cursor-agent test below for what guessing actually costs.
        for id in ["qwen", "amp", "droid", "goose", "crush", "gemini", "copilot"] {
            XCTAssertNil(Catalog.harness(id)?.authProbe?.statusCommand, id)
        }
    }

    func testClaudeProbeIsTheVerifiedJSONLane() throws {
        let probe = try XCTUnwrap(Catalog.harness("claude")?.authProbe)
        XCTAssertEqual(probe.statusCommand, ["auth", "status"])
        guard case let .json(loggedInKey, accountKey, planKey) = probe.format else {
            return XCTFail("claude prints JSON, verified 2026-08-30")
        }
        XCTAssertEqual(loggedInKey, "loggedIn")
        XCTAssertEqual(accountKey, "email")
        XCTAssertEqual(planKey, "subscriptionType")
    }

    func testCodexProbeIsTheVerifiedTextLane() throws {
        let probe = try XCTUnwrap(Catalog.harness("codex")?.authProbe)
        XCTAssertEqual(probe.statusCommand, ["login", "status"])
        guard case let .text(signedIn, _) = probe.format else {
            return XCTFail("codex prints a line of prose, verified 2026-08-30")
        }
        XCTAssertTrue(signedIn.contains("Logged in using"))
    }

    /// The finding that justifies the whole nil-means-we-will-not-guess rule,
    /// written down so nobody "helpfully" adds it later: `cursor-agent status`
    /// is NOT read-only. Run on 2026-08-30 it printed "Starting login
    /// process… Authenticating with Cursor…" and hung until killed.
    ///
    /// A status subcommand existing does not make it a status subcommand.
    func testCursorAgentHasNoStatusCommandBecauseItsStatusStartsALogin() throws {
        let probe = try XCTUnwrap(Catalog.harness("cursor-agent")?.authProbe)
        XCTAssertNil(probe.statusCommand)
        // It can still say where its credentials live, and still offer a login
        // — those are safe. Only the probe is refused.
        XCTAssertFalse(probe.credentialMarkers.isEmpty)
        XCTAssertNotNil(probe.loginCommand)
    }

    /// A declared status command with nothing to match on can only ever
    /// produce .unknown — a probe that runs a subprocess to learn nothing.
    func testEveryDeclaredStatusCommandCanActuallyDecideSomething() {
        for harness in Catalog.harnesses {
            guard let probe = harness.authProbe, probe.statusCommand != nil else {
                continue
            }
            switch probe.format {
            case let .text(signedIn, signedOut):
                XCTAssertFalse(signedIn.isEmpty && signedOut.isEmpty, harness.id)
            case let .json(loggedInKey, _, _):
                XCTAssertFalse(loggedInKey.isEmpty, harness.id)
            }
        }
    }

    /// The status command is arguments only — the binary comes from PATH
    /// resolution, never from the declaration. A declaration that could name
    /// its own executable would be a second, unreviewed launch path.
    func testStatusCommandsNameArgumentsNotBinaries() {
        for harness in Catalog.harnesses {
            for argument in harness.authProbe?.statusCommand ?? [] {
                XCTAssertFalse(argument.contains("/"), "\(harness.id): \(argument)")
                XCTAssertFalse(argument.hasPrefix("-"), "\(harness.id): \(argument)")
            }
        }
    }

    /// Markers are paths we STAT. They must be under the user's home and must
    /// never be a directory we would then be tempted to walk.
    func testCredentialMarkersAreHomeRelativeFiles() {
        for harness in Catalog.harnesses {
            for marker in harness.authProbe?.credentialMarkers ?? [] {
                XCTAssertTrue(marker.hasPrefix("~/"), "\(harness.id): \(marker)")
                XCTAssertFalse(marker.contains(".."), "\(harness.id): \(marker)")
            }
        }
    }

    // MARK: - Evaluation
    //
    // Fixtures below are REAL output captured from the live CLIs on
    // 2026-08-30, not invented shapes.

    private var claudeProbe: AuthProbe { Catalog.harness("claude")!.authProbe! }
    private var codexProbe: AuthProbe { Catalog.harness("codex")!.authProbe! }

    private let claudeSignedIn = """
    {
      "loggedIn": true,
      "authMethod": "claude.ai",
      "apiProvider": "firstParty",
      "email": "ryans51105@gmail.com",
      "orgName": "ryans51105@gmail.com's Organization",
      "subscriptionType": "max"
    }
    """

    func testClaudeSignedInYieldsAccountAndPlanItPrintedItself() {
        let state = AuthProbe.state(stdout: claudeSignedIn, exitCode: 0,
                                    markersPresent: true, probe: claudeProbe)
        XCTAssertEqual(state, .signedIn(account: "ryans51105@gmail.com", plan: "max"))
        XCTAssertTrue(state.isUsable)
    }

    func testClaudeLoggedInFalseIsSignedOut() {
        let state = AuthProbe.state(stdout: #"{"loggedIn": false}"#, exitCode: 0,
                                    markersPresent: true, probe: claudeProbe)
        XCTAssertEqual(state, .signedOut)
        XCTAssertFalse(state.isUsable)
    }

    func testCodexSignedInMatchesTheDeclaredLiteral() {
        XCTAssertEqual(
            AuthProbe.state(stdout: "Logged in using ChatGPT", exitCode: 0,
                            markersPresent: true, probe: codexProbe),
            .signedIn(account: nil, plan: nil))
    }

    func testCodexSignedOutMatchesItsOwnLiteral() {
        XCTAssertEqual(
            AuthProbe.state(stdout: "Not logged in", exitCode: 0,
                            markersPresent: true, probe: codexProbe),
            .signedOut)
    }

    /// THE honesty rule of this whole feature: a credential file existing is
    /// not proof of a working subscription. It may be expired, revoked, or
    /// for a different account.
    func testUnmatchedOutputWithAMarkerPresentIsUnknownNotSignedIn() {
        let state = AuthProbe.state(stdout: "some unexpected banner", exitCode: 0,
                                    markersPresent: true, probe: codexProbe)
        XCTAssertEqual(state, .unknown)
        XCTAssertNotEqual(state, .signedIn(account: nil, plan: nil))
    }

    /// No answer AND no credential on disk: signed out is the honest read.
    func testUnmatchedOutputWithNoMarkerIsSignedOut() {
        XCTAssertEqual(
            AuthProbe.state(stdout: "some unexpected banner", exitCode: 0,
                            markersPresent: false, probe: codexProbe),
            .signedOut)
    }

    func testNonZeroExitIsUnknownEvenIfTheTextWouldHaveMatched() {
        // A crashed CLI that happened to print the magic words has not told
        // us anything.
        XCTAssertEqual(
            AuthProbe.state(stdout: "Logged in using ChatGPT", exitCode: 1,
                            markersPresent: true, probe: codexProbe),
            .unknown)
    }

    func testNoStdoutAtAllIsUnknown() {
        for stdout in [nil, "", "   "] as [String?] {
            XCTAssertEqual(
                AuthProbe.state(stdout: stdout, exitCode: 0,
                                markersPresent: true, probe: codexProbe),
                .unknown, String(describing: stdout))
        }
    }

    /// A probe with no status command never runs one, so it can only report
    /// on markers — and a marker alone is never .signedIn.
    func testProbeWithoutAStatusCommandIsUnknownWhenAMarkerExists() {
        let probe = try! XCTUnwrap(Catalog.harness("cursor-agent")?.authProbe)
        XCTAssertEqual(
            AuthProbe.state(stdout: nil, exitCode: nil,
                            markersPresent: true, probe: probe), .unknown)
        XCTAssertEqual(
            AuthProbe.state(stdout: nil, exitCode: nil,
                            markersPresent: false, probe: probe), .signedOut)
    }

    func testExpiredIsReportedWhenTheCLISaysSo() {
        let probe = AuthProbe(statusCommand: ["s"],
                              format: .text(signedIn: ["Logged in"],
                                            signedOut: ["expired"]))
        // "expired" is declared as a signed-out literal, so it reads as such
        // rather than inventing a state nobody claimed.
        XCTAssertEqual(
            AuthProbe.state(stdout: "token expired", exitCode: 0,
                            markersPresent: true, probe: probe), .signedOut)
    }

    func testMalformedJSONIsUnknownNotSignedOut() {
        XCTAssertEqual(
            AuthProbe.state(stdout: "{not json", exitCode: 0,
                            markersPresent: true, probe: claudeProbe),
            .unknown)
    }

    func testJSONMissingItsAccountKeysStillReportsSignedIn() {
        XCTAssertEqual(
            AuthProbe.state(stdout: #"{"loggedIn": true}"#, exitCode: 0,
                            markersPresent: true, probe: claudeProbe),
            .signedIn(account: nil, plan: nil))
    }

    func testLoginCommandsAreOfferedForEveryProbeWeHave() {
        // A probe that can say "signed out" and cannot offer a way in is a
        // dead end with a label on it.
        for harness in Catalog.harnesses where harness.authProbe != nil {
            XCTAssertNotNil(harness.authProbe?.loginCommand, harness.id)
        }
    }
}

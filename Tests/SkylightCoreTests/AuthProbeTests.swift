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
        // It can still offer a login — that is safe. Only the probe is refused.
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

    /// Skylight names no credential path at all any more, and this keeps it
    /// that way. Markers could never honestly decide anything, so carrying the
    /// user's credential paths around was surface with nothing behind it — and
    /// the one we did carry for opencode was wrong on this very machine.
    func testNoProbeNamesACredentialPath() {
        for harness in Catalog.harnesses {
            guard let probe = harness.authProbe else { continue }
            let described = String(describing: probe)
            for secretish in ["auth.json", "claude.json", "oauth", "credential",
                              ".cursor", ".gemini"] {
                XCTAssertFalse(described.contains(secretish),
                               "\(harness.id) still names \(secretish)")
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
        let state = AuthProbe.state(stdout: claudeSignedIn, stderr: nil, exitCode: 0,
                                    probe: claudeProbe)
        XCTAssertEqual(state, .signedIn(account: "ryans51105@gmail.com", plan: "max"))
        XCTAssertTrue(state.isUsable)
    }

    func testClaudeLoggedInFalseIsSignedOut() {
        let state = AuthProbe.state(stdout: #"{"loggedIn": false}"#, stderr: nil, exitCode: 0,
                                    probe: claudeProbe)
        XCTAssertEqual(state, .signedOut)
        XCTAssertFalse(state.isUsable)
    }

    func testCodexSignedInMatchesTheDeclaredLiteral() {
        XCTAssertEqual(
            AuthProbe.state(stdout: "Logged in using ChatGPT", stderr: nil, exitCode: 0,
                            probe: codexProbe),
            .signedIn(account: nil, plan: nil))
    }

    func testCodexSignedOutMatchesItsOwnLiteral() {
        XCTAssertEqual(
            AuthProbe.state(stdout: "Not logged in", stderr: nil, exitCode: 0,
                            probe: codexProbe),
            .signedOut)
    }

    // The vendors use exit 1 for an expected signed-out result. These cases
    // follow their documented/source contracts, not a logged-out user account:
    // https://code.claude.com/docs/en/cli-reference
    // https://github.com/openai/codex/blob/459a79eb85400af759e9220c7bafb4429ae07516/codex-rs/cli/src/login.rs#L499-L501
    func testClaudeSignedOutExitMakesSignInReachable() {
        let state = AuthProbe.state(stdout: #"{"loggedIn": false}"#, stderr: nil,
                                    exitCode: 1, probe: claudeProbe)
        XCTAssertEqual(state, .signedOut)
        XCTAssertEqual(HarnessRowState.of(installed: true, subscription: state), .signedOut)
        XCTAssertNotNil(SubscriptionCopy.signInSpec(for: Catalog.harness("claude")!))
    }

    func testCodexSignedOutExitOnStderrMakesSignInReachable() {
        let state = AuthProbe.state(stdout: "", stderr: "Not logged in\n",
                                    exitCode: 1, probe: codexProbe)
        XCTAssertEqual(state, .signedOut)
        XCTAssertEqual(HarnessRowState.of(installed: true, subscription: state), .signedOut)
        XCTAssertNotNil(SubscriptionCopy.signInSpec(for: Catalog.harness("codex")!))
    }

    func testUnexpectedExitCannotReportSignedOutEvenWithRecognizedOutput() {
        for code in [nil, 2, 9, 127, -1] as [Int32?] {
            XCTAssertEqual(AuthProbe.state(stdout: #"{"loggedIn": false}"#, stderr: nil,
                                           exitCode: code, probe: claudeProbe), .unknown)
            XCTAssertEqual(AuthProbe.state(stdout: nil, stderr: "Not logged in",
                                           exitCode: code, probe: codexProbe), .unknown)
        }
    }

    func testExpectedSignedOutExitStillRequiresNegativeEvidence() {
        for output in ["", "Error checking login status", "Logged in using ChatGPT"] {
            XCTAssertEqual(AuthProbe.state(stdout: nil, stderr: output,
                                           exitCode: 1, probe: codexProbe), .unknown)
        }
        for output in ["", "{not json", "{}", #"{"loggedIn": true}"#] {
            XCTAssertEqual(AuthProbe.state(stdout: output, stderr: nil,
                                           exitCode: 1, probe: claudeProbe), .unknown)
        }
    }

    func testOtherProbesDoNotInheritVendorNegativeExitCodes() {
        let probe = AuthProbe(statusCommand: ["status"],
                              format: .text(signedIn: ["Signed in"], signedOut: ["Signed out"]))
        XCTAssertEqual(AuthProbe.state(stdout: "Signed out", stderr: nil,
                                       exitCode: 1, probe: probe), .unknown)
    }

    /// THE honesty rule of this whole feature: a credential file existing is
    /// not proof of a working subscription. It may be expired, revoked, or
    /// for a different account.
    /// Only the CLI's OWN words can produce signed-out. Anything else is a
    /// question we failed to answer, not a negative answer.
    func testUnmatchedOutputIsNeverSignedInOrSignedOut() {
        let state = AuthProbe.state(stdout: "some unexpected banner", stderr: nil, exitCode: 0,
                                    probe: codexProbe)
        XCTAssertEqual(state, .unknown)
    }

    func testNonZeroExitIsUnknownEvenIfTheTextWouldHaveMatched() {
        // A crashed CLI that happened to print the magic words has not told
        // us anything.
        XCTAssertEqual(
            AuthProbe.state(stdout: "Logged in using ChatGPT", stderr: nil, exitCode: 1,
                            probe: codexProbe),
            .unknown)
    }

    func testNoStdoutAtAllIsUnknown() {
        for stdout in [nil, "", "   "] as [String?] {
            XCTAssertEqual(
                AuthProbe.state(stdout: stdout, stderr: nil, exitCode: 0,
                                probe: codexProbe),
                .unknown, String(describing: stdout))
        }
    }

    /// C1, the rule this module broke where it hurt most.
    ///
    /// With no status command there is NOTHING to go on — a credential file's
    /// absence is not a statement about a subscription. Returning .signedOut
    /// there dims the row, ignores clicks, disables Create, and banners
    /// running surfaces, all on the strength of a path we guessed.
    ///
    /// Live failure this caught: opencode is installed, and its declared
    /// marker did not exist on this machine while a different, verified path
    /// did — so a working CLI was unlaunchable.
    func testNoStatusCommandIsAlwaysUnknownWhateverTheMarkersSay() throws {
        let probe = try XCTUnwrap(Catalog.harness("cursor-agent")?.authProbe)
        for present in [true, false] {
            XCTAssertEqual(
                AuthProbe.state(stdout: nil, stderr: nil, exitCode: nil, probe: probe),
                .unknown, "markers present: \(present)")
        }
        XCTAssertTrue(SubscriptionState.unknown.isUsable)
    }

    /// A marker-only harness stays LAUNCHABLE. This is the property that
    /// actually matters to someone using the app.
    func testMarkerOnlyHarnessStaysLaunchable() throws {
        for id in ["cursor-agent", "opencode"] {
            let harness = try XCTUnwrap(Catalog.harness(id))
            let state = AuthProbe.state(stdout: nil, stderr: nil, exitCode: nil,
                                        probe: try XCTUnwrap(harness.authProbe))
            XCTAssertEqual(state, .unknown, id)
            XCTAssertTrue(HarnessRowState.of(installed: true,
                                             subscription: state).canLaunch, id)
        }
    }

    /// I6: an unmatched TEXT answer is exactly as inconclusive as unparseable
    /// JSON. A codex release that rewords its status line must not silently
    /// block a CLI that works perfectly.
    func testUnmatchedTextIsUnknownNotSignedOut() {
        for stdout in ["Logged in via some new wording", "some unexpected banner"] {
            XCTAssertEqual(
                AuthProbe.state(stdout: stdout, stderr: nil, exitCode: 0, probe: codexProbe),
                .unknown, stdout)
        }
    }

    func testExpiredIsReportedWhenTheCLISaysSo() {
        let probe = AuthProbe(statusCommand: ["s"],
                              format: .text(signedIn: ["Logged in"],
                                            signedOut: ["expired"]))
        // "expired" is declared as a signed-out literal, so it reads as such
        // rather than inventing a state nobody claimed.
        XCTAssertEqual(
            AuthProbe.state(stdout: "token expired", stderr: nil, exitCode: 0,
                            probe: probe), .signedOut)
    }

    func testMalformedJSONIsUnknownNotSignedOut() {
        XCTAssertEqual(
            AuthProbe.state(stdout: "{not json", stderr: nil, exitCode: 0,
                            probe: claudeProbe),
            .unknown)
    }

    func testJSONMissingItsAccountKeysStillReportsSignedIn() {
        XCTAssertEqual(
            AuthProbe.state(stdout: #"{"loggedIn": true}"#, stderr: nil, exitCode: 0,
                            probe: claudeProbe),
            .signedIn(account: nil, plan: nil))
    }

    /// Caught by running the real CLI, not by any fixture: `codex login
    /// status` prints "Logged in using ChatGPT" on **stderr** and leaves
    /// stdout completely empty. A probe reading stdout alone resolves codex to
    /// .unknown forever, and the row silently never works.
    func testCodexAnswersOnStderrBecauseThatIsWhereItActuallyPrints() {
        XCTAssertEqual(
            AuthProbe.state(stdout: "", stderr: "Logged in using ChatGPT",
                            exitCode: 0, probe: codexProbe),
            .signedIn(account: nil, plan: nil))
    }

    /// stdout still wins when both speak — a CLI that prints its real answer
    /// on stdout and a warning on stderr must not be read off the warning.
    func testStdoutIsPreferredOverStderrWhenBothSaySomething() {
        XCTAssertEqual(
            AuthProbe.state(stdout: "Not logged in", stderr: "Logged in using ChatGPT",
                            exitCode: 0, probe: codexProbe),
            .signedOut)
    }

    /// JSON on stdout must not be corrupted by whatever a CLI logs to stderr.
    func testJSONIsParsedFromStdoutEvenWithNoiseOnStderr() {
        XCTAssertEqual(
            AuthProbe.state(stdout: claudeSignedIn,
                            stderr: "warning: update available",
                            exitCode: 0, probe: claudeProbe),
            .signedIn(account: "ryans51105@gmail.com", plan: "max"))
    }

    /// …and a CLI that puts its JSON on stderr is still readable.
    func testJSONIsFoundOnStderrWhenStdoutIsEmpty() {
        XCTAssertEqual(
            AuthProbe.state(stdout: "", stderr: #"{"loggedIn": true}"#,
                            exitCode: 0, probe: claudeProbe),
            .signedIn(account: nil, plan: nil))
    }

    func testBothStreamsEmptyIsStillUnknown() {
        XCTAssertEqual(
            AuthProbe.state(stdout: "", stderr: "", exitCode: 0,
                            probe: codexProbe),
            .unknown)
    }

    /// NON-EMPTY, not merely non-nil. `loginCommand: []` sailed through an
    /// XCTAssertNotNil and produced a harness with no Sign in button — a dead
    /// end with a label on it.
    func testLoginCommandsAreOfferedAndAreNotEmpty() {
        for harness in Catalog.harnesses {
            guard let probe = harness.authProbe else { continue }
            XCTAssertFalse(probe.loginCommand?.isEmpty ?? true,
                           "\(harness.id) declares a probe with no way to sign in")
        }
    }

    /// The rule the empty array violated, stated as the property that matters:
    /// anything that can be reported signed-out must have a way back.
    func testEveryHarnessThatCanReportSignedOutOffersAWayIn() {
        for harness in Catalog.harnesses {
            guard let probe = harness.authProbe, probe.statusCommand != nil
            else { continue }
            XCTAssertNotNil(SubscriptionCopy.signInSpec(for: harness),
                            "\(harness.id) can say signed-out with no Sign in")
        }
    }

    /// Gemini authenticates by API key as often as by login, so an
    /// unverified login command would have been a guess on top of a guess.
    /// It carries no probe at all now — .unknown, launchable, honest.
    func testGeminiCarriesNoProbeRatherThanAnEmptyOne() {
        XCTAssertNil(Catalog.harness("gemini")?.authProbe)
    }
}

import XCTest
import SkylightCore

/// The New sheet used to know two things about a harness: installed, or not.
/// There is a third, and it is the one that wastes people's time — installed,
/// but signed out, so Create launches a terminal that immediately fails.
final class HarnessRowStateTests: XCTestCase {
    func testNotInstalledOutranksEverything() {
        // Whatever we think we know about auth, the install command is the
        // only useful thing to say about a CLI that is not there.
        for state: SubscriptionState in [.unknown, .signedOut,
                                          .signedIn(account: nil, plan: nil)] {
            XCTAssertEqual(HarnessRowState.of(installed: false, subscription: state),
                           .notInstalled, "\(state)")
        }
    }

    func testInstalledAndSignedInIsReady() {
        XCTAssertEqual(
            HarnessRowState.of(installed: true,
                               subscription: .signedIn(account: "a@b.c", plan: "max")),
            .ready)
    }

    func testInstalledButSignedOutIsTheNewThirdState() {
        XCTAssertEqual(HarnessRowState.of(installed: true, subscription: .signedOut),
                       .signedOut)
    }

    /// `.unknown` reads as ready on purpose. Most harnesses have no verified
    /// probe at all, and refusing to launch something merely because we could
    /// not ask about it would break every CLI this feature does not cover —
    /// the CLI itself is perfectly capable of saying "please log in".
    func testUnknownIsTreatedAsReadyRatherThanBlocking() {
        XCTAssertEqual(HarnessRowState.of(installed: true, subscription: .unknown),
                       .ready)
        XCTAssertTrue(HarnessRowState.ready.canLaunch)
    }

    func testOnlyReadyCanLaunch() {
        XCTAssertTrue(HarnessRowState.ready.canLaunch)
        XCTAssertFalse(HarnessRowState.signedOut.canLaunch)
        XCTAssertFalse(HarnessRowState.notInstalled.canLaunch)
    }

    /// Every harness resolves to a LAUNCHABLE row on a machine where we have
    /// no answer — which is the normal case for the nine CLIs with no status
    /// command. (The previous version of this test never used `harness` at
    /// all: it evaluated one identical expression eleven times.)
    func testEveryHarnessIsLaunchableWhenWeHaveNoAnswer() {
        for harness in Catalog.harnesses {
            let state = HarnessRowState.of(
                installed: true,
                subscription: AuthProbe.state(stdout: nil, stderr: nil,
                                              exitCode: nil,
                                              probe: harness.authProbe
                                                ?? AuthProbe()))
            XCTAssertEqual(state, .ready, harness.id)
            XCTAssertTrue(state.canLaunch, harness.id)
        }
    }

    /// Exactly two harnesses can be asked; the rest report unknown. Pins the
    /// count so "six no-probe" style claims in docs stay true.
    func testOnlyTheVerifiedHarnessesCanBeAsked() {
        let askable = Catalog.harnesses.filter {
            $0.authProbe?.statusCommand != nil
        }.map(\.id)
        XCTAssertEqual(askable, ["claude", "codex"])
        XCTAssertEqual(Catalog.harnesses.count - askable.count, 9)
    }
}

final class SubscriptionCopyTests: XCTestCase {
    func testSignedOutCopyNamesTheHarness() {
        let copy = SubscriptionCopy.rowDetail(
            for: Catalog.harness("codex")!, state: .signedOut)
        XCTAssertEqual(copy, "Not signed in")
    }

    /// Account and plan are shown ONLY because the CLI printed them — never
    /// inferred, never prettified into a claim the vendor did not make.
    func testSignedInCopyShowsWhatTheCLIPrinted() {
        XCTAssertEqual(
            SubscriptionCopy.rowDetail(for: Catalog.harness("claude")!,
                                       state: .signedIn(account: "a@b.c", plan: "max")),
            "a@b.c · max")
        XCTAssertEqual(
            SubscriptionCopy.rowDetail(for: Catalog.harness("codex")!,
                                       state: .signedIn(account: nil, plan: nil)),
            "Signed in")
        XCTAssertEqual(
            SubscriptionCopy.rowDetail(for: Catalog.harness("claude")!,
                                       state: .signedIn(account: "a@b.c", plan: nil)),
            "a@b.c")
    }

    /// Nothing at all for unknown: a row that says "unknown" is noise on the
    /// eight harnesses we cannot ask about.
    func testUnknownSaysNothing() {
        XCTAssertNil(SubscriptionCopy.rowDetail(for: Catalog.harness("qwen")!,
                                                state: .unknown))
    }

    func testBannerNamesTheSignInCommandItWillRun() {
        let copy = SubscriptionCopy.bannerMessage(for: Catalog.harness("codex")!,
                                                  state: .signedOut)
        XCTAssertEqual(copy, "Codex isn't signed in — run codex login to connect it.")
    }

    func testBannerIsSilentWhenThereIsNothingToSay() {
        XCTAssertNil(SubscriptionCopy.bannerMessage(for: Catalog.harness("codex")!,
                                                    state: .unknown))
        XCTAssertNil(SubscriptionCopy.bannerMessage(
            for: Catalog.harness("codex")!, state: .signedIn(account: nil, plan: nil)))
    }

    /// A harness whose login we never verified must not print "run  to
    /// connect it" with a hole where the command should be.
    func testBannerWithoutAVerifiedLoginCommandStaysGeneric() {
        let copy = SubscriptionCopy.bannerMessage(for: Catalog.harness("gemini")!,
                                                  state: .signedOut)
        XCTAssertEqual(copy, "Gemini CLI isn't signed in.")
    }
}

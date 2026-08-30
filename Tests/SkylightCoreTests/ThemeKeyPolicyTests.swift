import XCTest
import SkylightCore

/// A config file is not a trusted script. Ghostty, kitty and wezterm configs
/// can all carry `command`, `keybind`, `include`, and environment directives —
/// Ryan's own ghostty config launches tmux. Importing a THEME must never be
/// able to change what a terminal runs.
final class ThemeKeyPolicyTests: XCTestCase {
    func testLookKeysAreImportable() {
        for key in ["background", "foreground", "palette", "cursor-color",
                    "selection-background", "background-opacity", "font-family",
                    "font-size", "window-padding-x", "cursor-style",
                    "minimum-contrast", "theme"] {
            XCTAssertEqual(ThemeKeyPolicy.decide(key), .importable, key)
        }
    }

    func testBehaviourKeysAreRefusedByName() {
        // Refused ≠ ignored: each one is NAMED back to the user, because a
        // silent drop is indistinguishable from a parser that never looked.
        for key in ["command", "keybind", "initial-command", "env",
                    "shell-integration", "include", "globinclude",
                    "config-file", "startup-command", "exec"] {
            XCTAssertEqual(ThemeKeyPolicy.decide(key), .refused, key)
        }
    }

    func testUnknownKeysAreIgnoredNotRefused() {
        // A key we simply do not handle is noise, not a threat — it must not
        // clutter the "we refused this" list the user reads.
        XCTAssertEqual(ThemeKeyPolicy.decide("macos-titlebar-style"), .ignored)
        XCTAssertEqual(ThemeKeyPolicy.decide("scrollbar"), .ignored)
        XCTAssertEqual(ThemeKeyPolicy.decide("window-width"), .ignored)
    }

    func testDecisionIsCaseAndWhitespaceInsensitive() {
        XCTAssertEqual(ThemeKeyPolicy.decide("  COMMAND "), .refused)
        XCTAssertEqual(ThemeKeyPolicy.decide("Background"), .importable)
    }

    /// The two sets must never overlap: a key that is both importable and
    /// refused would resolve by whichever check happened to run first.
    func testImportableAndRefusedNeverOverlap() {
        XCTAssertTrue(ThemeKeyPolicy.importableKeys
            .isDisjoint(with: ThemeKeyPolicy.refusedKeys))
    }

    /// Anything that can name a program or a file to read is refused. This is
    /// the rule stated as a test so a future key addition has to argue with it.
    func testNoImportableKeyCanNameAProgramOrPath() {
        for key in ThemeKeyPolicy.importableKeys {
            for danger in ["command", "exec", "include", "shell", "env", "bind"] {
                XCTAssertFalse(key.contains(danger),
                               "importable key '\(key)' looks executable")
            }
        }
    }
}

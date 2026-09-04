# Skylight quality and integration roadmap

September 4, 2026. Direction: a quiet, native terminal with powerful capabilities
revealed when needed. The normal workspace should stay visually simple.

## Implemented in this pass

- Prepare the session keeper off the main actor. Window and navigation remain
  available while session surfaces wait for readiness; daemon failure still
  enables the existing exec fallback.
- Add a transient Command-P workspace switcher. Search session names, provider
  names, folders, and canvases; open a canvas session in focus mode without
  rewriting its layout or zoom. Explicit native focus handoff restores typing.
- Share executable search paths between discovery, status checks, and agent
  launches. Preserve inherited PATH precedence and add common user tool locations.
- Coalesce sign-in refreshes per provider. A forced refresh during an active
  check discards the old answer and schedules one replacement. Failed verification
  does not prevent opening the CLI. Refresh installed tools when Settings returns
  to the foreground.
- Preserve the previously used GhosttyKit wrapper source locally because its
  locked upstream tag was unavailable. See Vendor/GhosttyKit/PROVENANCE.md.
- Package terminal resources in Contents/Resources; fail builds on signature or
  resource verification errors. Include license notices and run packaging in CI.
- Support an explicit isolated development workspace through SKYLIGHT_SUPPORT_DIR.

## Next work, ranked by user impact

| Priority | Work | Completion evidence |
| --- | --- | --- |
| 1 | Version-aware provider adapters: supported executable versions, status/login/resume commands, capabilities, and clear unsupported states. Keep vendor-owned login and subscriptions. | Fixtures per supported CLI version plus opt-in live checks. No guessed entitlement or quota claims. |
| 1 | Daemon compatibility and update recovery. Current protocol mismatch handling can terminate the old keeper and its sessions. Define safe negotiation and explicit recovery. | A long-running process keeps the same PID through supported app updates; incompatible state produces a recoverable explanation. |
| 1 | Trustworthy agent activity. Current inference uses output/title/bell/command events; quiet decay needs another event and is not authoritative provider state. | Prefer official structured CLI events where available; label inferred activity. Test idle, waiting, cancelled, disconnected, and resumed sessions. |
| 2 | Complete shell integration, including Bash startup semantics without replacing user configuration. | Real zsh, Bash, and fish tests for working directory, command duration, exit status, and custom startup files. |
| 2 | Stronger custom CLI profiles and project workspace templates on top of existing launch presets. | Open a project with chosen sessions and working directories; move it to a second machine without copying credentials or breaking paths. |
| 2 | Multi-session performance qualification. Existing read caps and backpressure deserve realistic mixed-load measurements. | Record typing latency percentiles with one noisy session, many quiet sessions, large scrollback, resize, and repeated reconnect. Compare before/after on identical hardware. |
| 2 | Full native interaction coverage. | Keyboard, VoiceOver, IME composition, Reduce Motion, Reduce Transparency, window sizes, and multi-display scaling all have repeatable checks. |
| 3 | Public distribution and updates. | Universal or clearly architecture-specific builds, Developer ID signing, notarization, update verification and rollback, and successful launch on a clean Mac. |

## Product decisions still needed

- The project currently contains PolyForm Noncommercial License 1.0.0. Review
  that choice against the intended free/unlimited positioning before advertising
  unrestricted professional use. This pass preserves the existing license.
- Skylight can remain free while invoking a user's installed CLI. Provider
  authentication, entitlements, quotas, and billing are separate product surfaces;
  display only capabilities that the provider actually exposes.
- Keep ordinary operations direct. Add settings, diagnostics, and provider detail
  through contextual panels and search instead of persistent dashboard chrome.

## Verification boundary

This pass ran 410 automated tests with zero failures, including native session
preparation/focus tests and daemon integration tests. An optimized app passed
strict signature and in-bundle resource verification. A build from an empty
scratch directory also succeeded using the machine's shared dependency cache.

Local UI checks use isolated harmless shell sessions, not paid provider accounts.
They do not establish a clean-machine public release, universal binary support,
provider-by-provider compatibility, or a measured percentage speed improvement.
Existing README performance figures were not re-benchmarked in this pass.

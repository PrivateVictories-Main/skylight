# GhosttyKit source snapshot

This directory preserves the terminal wrapper that Skylight was already using:

- Configured upstream: https://github.com/Lakr233/libghostty-spm
- Cached revision: `82584a5e2a6c808dcc9751851a9e849e1a9b05b4`
- Previous lockfile version: `1.4.9`
- Copied from the clean local SwiftPM checkout on September 4, 2026.

The configured upstream did not serve tag `1.4.9` when checked, and a separate
package resolution failed. Keeping this source in the repository preserves the
existing terminal behavior and makes those Swift sources available to fresh
checkouts. This is a preserved local snapshot, not a claim that upstream currently
publishes this revision.

The original MIT license is in `LICENSE`; resource and theme licenses are retained
under `Sources`. The compiled Ghostty XCFramework remains a remote, checksum-pinned
dependency declared in `Package.swift`. It is not copied here. The original
local-build manifest and release template are retained for maintenance.

Skylight-specific change: `GhosttyRuntimeResources` checks the app's resource
directory before SwiftPM's generated fallback, so macOS app bundles can use the
standard `Contents/Resources` layout and pass strict code-signature verification.

Update this snapshot deliberately, preserve license notices, and rerun Skylight's
tests, a fresh package build, and packaged resource verification after updates.

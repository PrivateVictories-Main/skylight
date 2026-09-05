# Development direction and remaining limits

The native macOS app defines Skylight's visual structure. Integrations belong in
New, preset settings, contextual menus, or focused settings screens. The terminal
and canvas should retain their quiet, rounded appearance.

This assessment is based on the current SwiftUI/Ghostty app, portable Tauri/Rust
implementation, actual macOS app checks, and Windows/Linux native WebDriver runs.
It separates functioning preview capabilities from the next engineering work.

| Area | Current state | Next acceptance gate |
| --- | --- | --- |
| Shared launch defaults | Per-OS preset settings now resolve on all three platforms; explicit file interchange | Machine-specific project-folder mappings and import-conflict review |
| Session survival | Native macOS keeper reconnects; portable sessions end when the app exits | Windows/Linux keeper with owner-only local IPC, bounded replay, reconnect, upgrade compatibility, and crash/restart tests preserving process identity |
| Canvas | Live overview, anchored navigation, grid/neighbor snapping, fit/arrange; native keyboard/pan/chrome defects fixed | Stable native reflow policy, complete docking parity, physical pinch/resize feel |
| Navigation placement | Left sidebar with collapse; native painted top band removed | Shared left/right/top/bottom preference, appropriate horizontal presentation, stable terminal hosts and keyboard/accessibility checks |
| Provider integration | Shared CLI discovery; native Claude/Codex signed-out status corrected | Portable onboarding, verified/pinned brand assets, provider-by-provider login/resume/cancel checks |
| Theme and appearance | Shared 485-theme catalog; portable live controls and Ghostty/Windows/VS Code imports with durable undo; native imports/storage repaired | Native image backgrounds, remaining import formats and fields, theme interchange, full light-mode/contrast and picker verification |
| Terminal behavior | Real Unix PTYs and Windows ConPTY; bounded independent I/O and exit handling | PowerShell, WSL, interactive TUIs, large Unicode output, clipboard, IME, accessibility, and resize stress coverage |
| Performance | Renderers retained for visible terminals; bounded scrollback/output and deferred discovery | Input-to-visible-output latency, startup and many-session memory/CPU budgets measured on real Windows/Linux/macOS hardware |
| Distribution | Verified macOS bundle; built Windows NSIS and Linux deb previews | Installer/upgrade/uninstall checks, signing decisions, release/update delivery, more distro/client-machine coverage |
| Cross-device work | Explicit portable preset/workspace files | Only after local reliability: optional authenticated remote attachment with clear ownership, revocation, and session lifecycle |

## Order of work

1. Keep launch configuration portable and recoverable; require real process/cwd
   evidence when a launcher changes. This pass adds per-OS presets and avoids
   silently losing other-platform entries during native import.
2. Resolve the reported canvas reflow/placement choices, then close the session-survival gap. A separate keeper is a substantive backend
   project: test quiet and flooded terminals, renderer loss, conflicting app
   instances, reconnect, and protocol upgrades before calling it parity.
3. Expand canvas and provider behavior through focused, tested changes. Preserve
   ordinary shell shortcuts and keep advanced UI on demand.
4. Establish hardware performance and distribution gates. VM screenshots and
   successful compilation cannot establish physical latency, IME behavior, or
   installer quality.

Each implementation pass should publish its tested source, measured scope, known
limits, and target-OS evidence to GitHub. Current records:
[visual design](visual-design.md), [desktop verification](quality-verification.md),
[session recovery](session-recovery.md), [platform presets](platform-presets.md),
[platform preset verification](platform-preset-verification.md), and
[customization and navigation audit](customization-navigation.md).

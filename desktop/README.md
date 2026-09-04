# Skylight for Windows and Linux — development preview

A sibling desktop implementation of Skylight. The production macOS application
stays SwiftUI/Ghostty; this directory uses Rust, Tauri 2, and xterm.js. It is a
working foundation, not a claim of platform or feature parity.

## Included

- Real local terminal processes: Unix PTYs and Windows ConPTY via portable-pty.
- Normal shells or installed AI CLIs, with explicit executable, working folder,
  and argument settings. Detection is not a claim of sign-in or entitlement.
- Named presets in the **New** dialog. Save a shell/CLI configuration, edit it, or
  start another independent session with one click.
- Native file dialogs for importing/exporting workspace JSON and native macOS
  preset arrays. Plain version-2 workspace files remain readable; geometry,
  edge-dock metadata, and unknown JSON fields are retained.
- Session sidebar and keyboard search; movable/resizable canvas tiles, overview
  zoom, and full-window terminal focus. At 100% canvas tiles are live terminals.
- WebGL rendering with xterm's built-in renderer as fallback. Visible terminals
  keep their renderer during status updates and moves; inactive surfaces release
  it. Scrollback is bounded independently per terminal.
- Launch settings open immediately while provider discovery refreshes in the
  background. The first move to a canvas creates it and places the terminal in
  one flow; live tiles update their process status while preserving typing focus.
- Raw binary output through Tauri channels, a 128 KiB unacknowledged output window
  per session, and a separate bounded input worker. A noisy producer backpressures
  its own PTY. No terminal output is treated as HTML or used to run app commands.
- Atomic workspace saves and an exclusive workspace lock; corrupt or unsupported
  input is reported without replacing the saved file.

## Same quiet workspace

The native macOS app is the visual reference. Windows and Linux share its
256-point sidebar, bottom **New** button, neutral charcoal surfaces, 8-point
terminal inset, 16-point panel corners, 30-point canvas headers, 560 × 400
initial tiles, and sparse 64-point canvas grid. Terminals fill their panel
without a permanent action toolbar. System title bars and installed fonts can
differ across operating systems; the Mac's native material is not emulated with
a costly web blur.

Right-click a terminal row, use its **⋯** button, or press **Shift+F10** while the
row is focused for launch settings, presets, canvas placement, and close.
Workspace-wide commands are under the small **⋯** button above the sidebar.
Saved presets appear in **New**, and **Launch options** reveals names, executable
paths, and arguments. Search can launch presets directly.

Canvas zoom is in the workspace or canvas context menu. Double-click empty canvas
space to create a terminal on that board. The tile's expand button fills the
window; its **×** returns it to the sidebar without ending the process. The
sidebar toggle makes more room for terminal output.

Native WebDriver checks enforce the measured sidebar width, panel inset/corners,
absence of a terminal toolbar, canvas header height, and grid spacing on both
Windows and Linux, alongside real terminal input and saved-workspace checks.

## Launch presets across computers

On macOS: **File → Export Launch Presets…** produces `skylight-presets.json`.
In this preview: **Workspace menu (⋯) → Import workspace** adds those presets to
**New → Saved presets**. Inspect the
executable and folder using the preset's edit button before launching locally.

In this preview: **Workspace menu (⋯) → Export workspace** produces a version-2 workspace including
`launchPresets`. On macOS, **File → Import Launch Presets…** reads that field.
This transfers launch configuration. It does not read CLI credential stores or
transfer provider subscriptions, running processes, or command history. Explicit
argument values are included, so secrets should stay in the CLI’s own credential store. Filesystem paths
may need changing on each machine. There is no automatic cloud sync or remote
terminal service in this implementation.

## Develop

Install the platform requirements from [Tauri's official prerequisites](https://v2.tauri.app/start/prerequisites/).
Use Node 22 and a current stable Rust toolchain. Then, from this directory:

```sh
npm ci
npm run tauri -- dev
```

The preview uses its own application identifier and data directory. For an
isolated QA fixture, set `SKYLIGHT_PORTABLE_SUPPORT_DIR` to an absolute directory.
Saved sessions reopen as stopped launch configurations; they do not run on import
or application start. Window close asks before ending active sessions.

```sh
npm test
npm run build
cargo fmt --all -- --check
cargo clippy --locked --workspace --all-targets -- -D warnings
cargo test --locked -p skylight-runtime
```

The Rust tests include real shell input/resize/exit, output saturation followed
by cancellation, and an independent terminal continuing during the flood. The
Windows CI additionally exercises a batch launcher with a spaced argument.

## Package on the target OS

Initial CI package targets are x86-64 Windows and Ubuntu/Debian Linux. ConPTY
requires Windows 10 version 1809 or newer ([Microsoft API requirements](https://learn.microsoft.com/en-us/windows/console/createpseudoconsole#requirements));
modern Windows 11 is the intended client validation target. These are build
targets and API prerequisites, not a completed supported-device certification.


Windows:

```powershell
npm run tauri -- build --bundles nsis
```

Ubuntu/Debian:

```sh
npm run tauri -- build --bundles deb
```

`.github/workflows/portable.yml` tests and builds these packages on Windows 2022
and Ubuntu 24.04 runners and stores workflow artifacts. Native WebDriver then
drives the built app through shell creation, presets, canvas movement/resize/zoom,
close cancellation, exit/restart, and saved-workspace recovery. Real shell commands
must create marker files in the configured working folder. Screenshots and a JSON
check report are uploaded as `skylight-ui-evidence-*`, including failure evidence.
UI evidence is retained for seven days and installers for fourteen days.
The elapsed times in that report include automation overhead; they are not
input-to-render benchmarks. Provider sign-ins, native file dialogs, installers,
IME, and physical hardware are outside this smoke suite.

CI runs only on public repositories using standard hosted runners, which
[GitHub provides free for public projects](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).
The private source mirror skips these jobs to avoid consuming private minutes.
For local Linux UI checks, install `webkit2gtk-driver`, `xvfb`, and
`cargo install tauri-driver --version 2.0.6 --locked`, build the release app, then
run `dbus-run-session -- xvfb-run -a sh e2e/linux-desktop.sh` on a virtual
display with Openbox installed. Windows requires a matching Microsoft
Edge driver on PATH and uses `node e2e/smoke.mjs`. The CI setup follows
[Tauri's native WebDriver guidance](https://v2.tauri.app/develop/tests/webdriver/ci/).

The workflow does not publish a
GitHub release. Windows signing, Linux distribution validation, update delivery,
and hardware performance qualification are release gates, not completed features.

For developer UI checks on a Mac, `npm run tauri -- build --debug --bundles app`
can build a separate preview. This is not a replacement for the native macOS app.

## Keyboard

Windows/Linux use **Ctrl+Shift+T** for New and **Ctrl+Shift+P** for workspace search,
leaving shell Ctrl+T/Ctrl+P bindings alone. The Mac development host uses Command.
Search uses arrows, Enter, and Escape. Results marked **Launch preset** open a fresh
session from saved settings; terminal results return to an existing session.
A tile's resize grip supports arrows too.

## Still required before parity

1. A separate portable session keeper with authenticated local IPC, reconnect,
   replay, and compatible upgrade handling. This preview ends sessions when the
   app exits; it does not yet match native macOS session survival.
2. Windows/Linux live tests for each provider version, account detection, resume,
   cancellation, Unicode/IME, clipboard, accessibility, and interactive TUIs.
3. Full edge-rail docking, canvas snapping/arrangement, theme parity, shell
   integration, and platform-specific default overrides for shared presets.
4. A native-OS input-to-render benchmark matrix. No performance equivalence to
   the SwiftUI/Ghostty version is claimed from compilation or host-only tests.

Windows batch wrappers run through installed PowerShell; arguments containing
cmd.exe metacharacters are explicitly rejected. Run such commands in a shell or
select a native executable until that additional argument contract is supported.

Architecture references: [Tauri webview architecture](https://v2.tauri.app/reference/webview-versions/),
[Tauri channels](https://v2.tauri.app/develop/calling-frontend/#channels),
[xterm flow control](https://xtermjs.org/docs/guides/flowcontrol/),
[portable-pty](https://docs.rs/portable-pty/0.9.0/portable_pty/).

Runtime lifecycle details and recovery behavior are documented in
[the recovery guide](../docs/session-recovery.md).

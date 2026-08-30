# Changelog

## v0.2.0 — unreleased

The session-survival release: quitting Skylight no longer ends anything.

### Sessions survive the app
- `skylightd`, a tiny bundled daemon, owns every pty over a user-only unix
  socket; the app is a renderer that reattaches. Quit, crash, or force-quit
  and relaunch — same processes, scrollback intact. Reattach replays a full
  1 MiB scrollback ring in ~2 ms.
- End-to-end flow control: a slow consumer blocks the child on its tty like
  any real terminal; a detached flood is pulse-sampled for under 1% daemon
  CPU; a client-side token bucket keeps the renderer's parse queue bounded.
- Zero-leak orphan hygiene as a tested property: a successor daemon sweeps
  HUP-immune leftovers from a killed predecessor's ledger.
- Measured, reproducibly (`./scripts/bench.py`): ~20 µs keystroke round
  trip, ~150 MB/s per core throughput, ~11 MB daemon RSS under flood.

### The look is yours
- Settings (⌘,): Appearance (System/Light/Dark), Window Background
  (Glass/Flat — Flat truly flattens the sidebar too), Terminal Background
  (Clear ↔ Solid), and Text Size. Every control applies instantly to every
  open terminal.
- Reduce Transparency in System Settings outranks all of it, live —
  including inside the terminals.

### Canvas and navigation
- Zoom with an honest contract: 100% is fully interactive and pixel-crisp;
  any other zoom is an overview, and clicking a tile flies back to it.
- Any-edge/corner tile resize with magnet snapping; ⇧⌘A arranges the board;
  window shrink reflows the arrangement to stay visible.
- Focus mode borrows the whole window for one tile; ⌘. hands it back.

### Agent terminals
- Eleven agent CLIs detected and launchable, each wearing its vendor's mark
  where one exists; agent terminals name themselves after the first prompt.
- Per-harness Full Autonomy toggles that name the exact flag they pass,
  off by default.
- Honest session state everywhere: bell attention dots, a Dock badge,
  "Session ended" with one-click restart, and launch-time fallback banners.

## v0.1.0 — 2026-08-08

First public cut: the terminal canvas. Sidebar terminals, endless canvases,
drag-reveals-canvas, live Ghostty tiles, the tiered New sheet with usage
recommendations and presets, and persistence that survives hostile data.

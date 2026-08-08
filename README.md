# Skylight

A macOS-native terminal canvas. Terminal instances live in a left sidebar;
drag one and the window becomes an endless canvas where terminals are live,
draggable, resizable tiles. Swift + SwiftUI, with real Ghostty terminals.

## What it does

- **Real terminals** — GhosttyKit surfaces running your actual shell (zsh,
  bash, fish — whatever `/etc/shells` offers).
- **Endless canvases** — as many boards as you like; pan forever; every tile
  is a live session. Layout and pan position persist and restore instantly.
- **Drag-reveals-canvas** — start dragging a sidebar row and the canvas
  appears with a live ghost of where the tile will land. Drop it there; drag
  it back out and it's a full-window terminal again. A session survives every
  move.
- **Focus mode** — expand any tile to the full window; ⌘. puts it back with
  the canvas exactly as it was. (Escape belongs to the terminal — vim and
  TUIs need it — so the exit is a real menu command.)
- **Agent terminals** — a terminal can launch an agent CLI (Claude Code,
  Codex, Gemini CLI, OpenCode) on your existing subscription. Skylight
  detects what's installed and never fakes what isn't.
- **A New sheet that learns** — shell → mode → harness in one tiered sheet;
  your most-used combo becomes a one-click row; save any combo as a named
  preset for one-button launches.
- **Attention badges** — a background terminal that rings its bell gets a
  pulsing sidebar dot until you look.

## What it deliberately isn't

- No chat UI, no web views, no API keys, no network calls, no telemetry.
  The launch statistics behind recommendations are one local JSON file.
- One terminal engine: Ghostty, embedded via GhosttyKit. kitty and iTerm are
  apps, not libraries — Skylight won't pretend to embed them.
- No zoom (v1): scaling a live terminal blurs glyphs and breaks hit-testing.
  Pan is endless and exact instead.

## Keyboard

- **⌘T** — New Terminal… (the tiered sheet)
- **⇧⌘T** — new shell terminal, launched instantly
- **⇧⌘N** — new canvas
- **⌘.** — back to canvas (leave focus mode)

## Build & run

```
./scripts/make-app.sh && open build/Skylight.app
```

macOS 14+, Swift 6 toolchain. Debug appearance override:
`SKYLIGHT_APPEARANCE=dark ./build/Skylight.app/Contents/MacOS/Skylight`

## Architecture

Two targets, tests on the pure part:

- **SkylightCore** — models, layout math, shell/harness detection,
  recommendations, persistence + migration. No UI imports; unit-tested
  (`swift test`).
- **Skylight** — the SwiftUI app: `AppState` + `LiveSessionStore` (sessions
  outlive view churn), sidebar / canvas / sheet views.

The invariant everything obeys: **a running session survives every
transition** — full-window ↔ canvas ↔ other canvas ↔ focus.
`LiveSessionStore` owns each terminal NSView; SwiftUI only reparents it.

## Note for pre-carve users

Skylight once had an AI-chat layer. Its data is still on disk at
`~/Library/Application Support/Skylight/` (`chats/`, `webhistory/`) — the app
ignores it and will never delete it. Remove those folders manually if you
want the space back.

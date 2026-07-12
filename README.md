# Skylight (working name)

macOS-native AI workspace: your Claude + ChatGPT subscriptions, real Ghostty terminals, and agent CLIs — unified behind a ChatGPT-app-style sidebar where a **Canvas** is a first-class item: drag chats and terminals onto a snapping board of live tiles, click away, come back to everything where you left it.

## Status: proof-of-concept (v0.1 spike, 2026-07-12)

Verified working:
- Sidebar (Chats / Terminals / Canvases) with full-window detail views
- Real terminal tiles via GhosttyKit (libghostty) — `.exec` backend, real zsh
- Subscription chat tiles via WKWebView (claude.ai / chatgpt.com, Safari UA, OAuth pops out to default browser)
- Canvas boards: drag from sidebar or right-click → Add to Canvas; draggable/resizable/snapping tiles; layout persists to Application Support
- Live-session store: the same chat/terminal keeps state full-window, on canvas, and across navigation

## Build & run

```
./scripts/make-app.sh && open build/Skylight.app
```

## Next
- Agent CLI presets (claude / codex / opencode launched in terminal tiles)
- OpenCode server + SDK as native API-chat engine
- Session persistence daemon (zmx-style) so terminals survive relaunch
- Chat → terminal handoff; canvas auto-naming; polish pass (Liquid Glass)

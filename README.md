# Skylight (working name)

A macOS-native AI workspace: your Claude, ChatGPT, and Gemini subscriptions, real Ghostty terminals, and interactive agent sessions — one app, styled after the unified ChatGPT/Codex desktop app, with a canvas where everything becomes draggable live tiles.

**Chatting never goes through the web.** Native chat drives each vendor's own CLI (Claude Code, Codex, Gemini CLI) on your existing subscription — no API keys, no reverse engineering. The web surface exists only as an optional history view.

## What works today

- **Unified assistants** — one sidebar item per provider with a sliding Chat / Code / Web mode switcher
- **Native chat** — custom composer (attachments via picker or drag-drop), streamed replies, markdown + code blocks with copy, starter suggestions, auto-titles refined by a background model call
- **Models & effort** — only the newest generation + one previous per provider (ChatGPT list reads Codex's live model cache); reasoning effort as a draggable snapping slider, bounds adapting per model (Claude: low→max via `--effort`; GPT 5.6 Sol/Terra reach ultra)
- **Real terminals** — GhosttyKit surfaces; plain zsh or agent sessions (Claude Code / Codex / Gemini CLI) with live activity captions in the sidebar
- **Chat → agent handoff** — one button turns a conversation into a live agent session with context carried over (typed in, not auto-submitted)
- **Canvas** — Freeform-style boards of draggable, resizable, snapping live tiles (chats, terminals, web); tiles lift and spring while grabbed
- **ChatGPT-app-grade shell** — customizable sidebar (pin, rename, delete-with-confirm, show/hide sections), profile chip, new-item picker with brand tiles + install states, keyboard shortcuts, dark mode, generated app icon

## Build & run

```
./scripts/make-app.sh && open build/Skylight.app
```

Requires the vendor CLIs for native chat: `claude` (installed), `codex` (installed), `gemini` (`npm i -g @google/gemini-cli`).

Debug appearance: `SKYLIGHT_APPEARANCE=dark ./build/Skylight.app/Contents/MacOS/Skylight`

## Next

- Handoff timing hardening (detect CLI prompt-readiness before injecting)
- Agent attention badges (waiting-for-input notifications)
- Terminal session persistence across relaunch (zmx-style)
- Ask-everyone: one prompt fanned to all providers as canvas tiles
- Projects: group chats + agents + canvas per repo/working directory

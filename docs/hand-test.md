# Skylight hand-test checklist

`pkill -9 -x Skylight; ./scripts/make-app.sh && open build/Skylight.app`
then walk top to bottom. Every line should feel instant.

- [ ] Cold launch restores the last session: instances, canvases, pan
      positions, selection.
- [ ] First run after the carve: chats are gone from the sidebar; terminals
      survived with their names; old data stayed on disk
      (`~/Library/Application Support/Skylight/chats/` — ignored, not
      deleted).
- [ ] ⌘T opens the New sheet; ⇧⌘T instantly opens a plain terminal;
      ⇧⌘N a canvas; ⌘. is the only way back out of focus mode.
- [ ] New sheet: shell list matches `/etc/shells`; harness rows show honest
      installed/dimmed states; args + directory stick; Create launches;
      a saved preset launches in one click; after 3 launches of the same
      combo the "Your usual" row appears.
- [ ] Drag a sidebar terminal row: the canvas reveals mid-drag, the ghost
      tracks the cursor and matches where the tile lands; chips drop onto
      other canvases and New Canvas; Esc mid-drag cancels cleanly.
- [ ] Run `top` in a terminal, drag it onto a canvas, back out, onto another
      canvas: the same `top` keeps scrolling — it never restarts.
- [ ] Trackpad pan feels like paper under your fingers (if inverted, flip
      the sign in `PanSurface.PanView.scrollWheel`); click-drag on empty
      space pans; scrolling over a tile scrolls the terminal buffer instead.
- [ ] Click a canvas-resident sidebar row → its canvas opens centered on
      that tile with a spring.
- [ ] Double-click a tile header (or its expand button) → focus mode fills
      the window; ⌘. returns; the canvas is untouched. Escape stays with the
      terminal (try it in vim — it must not exit focus).
- [ ] Bell: run `sleep 2; printf '\a'` in a terminal, switch away before it
      fires → pulsing sidebar dot; opening the terminal clears it.
- [ ] Delete a canvas → its terminals return to the Terminals section,
      sessions alive.
- [ ] Quit test: create a terminal running `sleep 999`, quit Skylight,
      `pgrep -f "sleep 999"` → empty (no orphaned children).
- [ ] Glass: tiles and full-window terminals wear material chrome with a lit
      hairline; the terminal background is faintly translucent (the dot grid
      breathes through on a canvas); dark AND light both look premium. If the
      ghostty surface renders translucency wrong (black/artifacts), say so —
      the fallback is opaque terminal + glass chrome.
- [ ] Magnet: drag a tile to within ~12pt of another's edge → it aligns or
      abuts flush; far from everything → 16pt grid snap as before.
- [ ] Reflow: shrink the window with tiles near the right edge → they shift/
      scale to stay visible and the terminal text rewraps (nothing clipped);
      growing the window back never rearranges anything.
- [ ] Idle CPU ≈ 0% in Activity Monitor with 3 idle terminals after a
      minute; drag a tile in circles — smooth the whole way on the 45".
- [ ] `SKYLIGHT_APPEARANCE=dark` and `=light` both look clean.

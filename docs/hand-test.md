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
- [ ] Resize a tile by its corner handle: smooth, snaps to the 16pt grid on release, terminal reflows to the new cells.
- [ ] Pan a canvas until a tile is fully off-screen, then click where it would be (over the sidebar / empty canvas): nothing invisible responds. If an unseen tile reacts, report it — the fix is a contentShape after .clipped.
- [ ] Drop a terminal onto an already-visible canvas: judge the recenter — the board pans to center the new tile. If that feels like a yank, say so.
- [ ] With an agent terminal whose CLI is NOT installed (or temporarily renamed away): the tile runs your shell and a capsule banner says which CLI is missing and how to install it.
- [ ] Magnet check at distance: a tile far away VERTICALLY still magnets your X axis — judge whether that helps or surprises.
- [ ] Zoom: pinch on the trackpad — cursor-anchored, snaps to exactly 100%
      when close; ⌘0 = 100%, ⌘+/⌘− step, ⌘9 fits; at any zoom other than
      100% clicking a tile flies to it at 100% and typing works right after.
- [ ] Zoom crossing: sit at ~80% (⌘0 on a big board), press ⌘+ once —
      it must land exactly ON 100% (typable), never at 105%.
- [ ] Overview drag: zoomed out, drag a tile — it moves (doesn't dive);
      a plain click dives. Resize badges are hidden at overview zoom.
- [ ] Window drag: with the sidebar open, drag the window by the bottom-left
      bar band; with it collapsed, by the slim top strip. During a tile drag
      the window must NOT move; after ⇧⌘T pressed mid-tile-drag (canvas swaps
      away), the window must still be draggable.
- [ ] Edge-resize cursors: hover each edge/corner of a tile — correct arrows,
      no cursor stuck after leaving; resize from every edge, far edge never
      moves (also after a window-shrink reflow made tiles off-grid).
- [ ] Arguments with spaces: New sheet → agent + `--dir "/tmp/My Dir"` style
      argument → the CLI receives it as ONE argument.
- [ ] Session end honesty: run a ⇧⌘T terminal, type `exit` — the sidebar row
      says "Session ended"; Restart Session brings it back live; Delete's
      warning says the session already ended.
- [ ] Quit: with the keeper running, ⌘Q asks nothing (sessions survive);
      the warning dialog only exists in the SKYLIGHT_NO_DAEMON lane below.
- [ ] Full autonomy toggles: per-harness switch in ⌘T names the exact flag;
      newly verified — gemini `--yolo`, copilot `--allow-all-tools`,
      cursor `--force`.
- [ ] Idle CPU ≈ 0% in Activity Monitor with 3 idle terminals after a
      minute; drag a tile in circles — smooth the whole way on the 45".
- [ ] Hidden surfaces idle: put `top` tiles on a canvas, select a different
      terminal — CPU drops (hidden surfaces stop rendering); switching back
      shows the canvas instantly with current content, no stale frames.
- [ ] Mouse-wheel pan: free-spin the MX wheel over a canvas — smooth, no
      hitching (commits now settle trailing, not per notch).
- [ ] Flood: run `yes hello` in a tile — the app stays responsive (other
      tiles type fine), memory holds steady, and ⌃C stops it instantly.
      Quit mid-flood, relaunch: the flood resumes into the replay.
- [ ] Kinds unchanged after the InstanceKind carve: agent rows still wear
      their vendor mark, shell rows the terminal glyph, in the sidebar AND on
      tile headers; names still issue as "Claude Code" / "zsh" / "Terminal".
- [ ] `SKYLIGHT_APPEARANCE=dark` and `=light` both look clean.
- [ ] Focus transition: enter/leave focus mode repeatedly — the terminal
      surface must never go blank or vanish after the cross-fade.
- [ ] SURVIVAL, the flagship: run `top` in a terminal, ⌘Q (note: no dialog —
      nothing is lost now), relaunch → the same `top` is still scrolling,
      scrollback intact. Then Force Quit the app instead → same result.
- [ ] Survival feel: typing latency through the daemon lane must be
      indistinguishable from before; open vim, quit the app, relaunch —
      judge the repaint (the replay lands on the settled grid; a frame
      older than the 1 MiB ring may need a keystroke/^L to redraw).
- [ ] Reattach is byte-perfect: with a shell prompt showing, quit and
      relaunch (and separately: close the window, click the Dock icon) —
      the grid comes back EXACTLY as it was: no stray %, no shifted
      prompt, no redraw flicker.
- [ ] Delete honesty with the keeper: delete a running terminal → its
      process actually ends (`pgrep` it); deleting the last one ends
      `skylightd` itself within seconds.
- [ ] `SKYLIGHT_NO_DAEMON=1` launch: everything behaves as before the
      daemon existed, including the ⌘Q warning dialog.
- [ ] A session that ends while the app is CLOSED (exit the shell via ssh
      or kill it): next launch shows its final output and "Session ended".
- [ ] Settings (⌘,): flip Appearance between Light/Dark/System — instant,
      including ghostty's own colors; System tracks a live OS toggle.
- [ ] Glass ↔ Flat: flip Window Background — the SIDEBAR goes flat too
      (its material stops sampling the desktop), and back. No relaunch.
- [ ] Terminal Background slider: with a busy terminal open, drag from
      Solid toward Clear — the open terminal follows the thumb live, glass
      arriving through the text area; canvas tiles follow too. Choices all
      survive a relaunch.
- [ ] Reduce Transparency (System Settings → Accessibility → Display):
      flip it ON with terminals open — window AND terminal surfaces go
      solid live; the Settings pane says the system setting is in charge;
      flip OFF → the stored glass choices return.
- [ ] Theme applies LIVE: with 3 terminals open (one full-window, two tiles),
      pick a bundled theme — all three recolour at once, no relaunch, and the
      choice survives a relaunch. Opening a NEW terminal shows the theme from
      its first frame (no flash of the old colours).
- [ ] Theme vs Reduce Transparency: with a translucent theme applied, turn
      Reduce Transparency ON — every surface goes solid live and stays solid
      through a theme change; OFF restores the theme's own translucency.
- [ ] Text Size: change it in ⌘, with terminals open — every open
      terminal reflows live at the new size, colors untouched; Default
      returns to the engine size; the choice survives relaunch.

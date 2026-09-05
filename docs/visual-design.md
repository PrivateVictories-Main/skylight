# One Skylight workspace across platforms

The SwiftUI macOS application defines the visual direction. The Windows and Linux
implementation should look like the same application: a quiet workspace, with
configuration revealed when needed. New integrations should fit that hierarchy
instead of adding permanent dashboard sections or toolbars.

## Reference surfaces

- `Sources/Skylight/ContentView.swift`: sidebar, bottom New button, terminal panel,
  and focused canvas terminal.
- `Sources/Skylight/CanvasView.swift`: sparse canvas, terminal tile headers,
  focus/remove buttons, and rounded tile boundaries.
- `Sources/Skylight/NewTerminalSheet.swift`: presets and progressive launch choices.
- `Sources/SkylightCore/Layout.swift`: default 560 × 400 tiles and 16-point grid.

The September 4 local comparison used the actual native app in dark, solid
appearance with an isolated workspace. It did not use the portable Mac development
build as the macOS design reference.

## Portable visual contract

| Surface | Contract |
| --- | --- |
| Sidebar | 256 logical pixels; frame inset 8 pixels with 16-pixel corners; blue active selection, neutral inactive selection |
| Bottom New | 30-pixel height, 10-pixel corners, 17 pixels above the window bottom |
| Full terminal | 8-pixel inset, 16-pixel corners, no permanent action toolbar |
| Focused canvas terminal | A 28-pixel back bar, integrated into the panel |
| Canvas | Full-height field, 64-pixel dots at 100%, grid follows pan and zoom |
| New tile | 560 × 400, centered/revealed at live scale |
| Tile header | 30 pixels, 12-pixel terminal glyph, 10-pixel SVG focus/remove controls |
| Tile edge | 16-pixel corners, fading top highlight, quiet 5-pixel-offset shadow |
| Terminal scrollbar | Rounded inset thumb; existing full-width pointer target retained |
| Actions | Context menu / row overflow; keyboard reachable with Shift+F10 |
| Presets | In New and workspace search; no separate permanent sidebar section |
| Launch configuration | Run and folder first; executable/name/arguments under Launch options |
| Typography | Locally bundled Inter UI and JetBrains Mono; no runtime font downloads |
| Forms | 16-pixel dialog corners, 8-pixel field corners, shared select appearance and chevron |

Folder captions show the final directory component; hovering reveals the complete
launch path. Search and execution retain the full path. Line icons replace
font-dependent arrow and close characters, so control shapes are consistent across
the Windows and Linux renderers. Blue primary buttons and active selection follow
the default native macOS accent; inactive window selection stays neutral.

System window decorations, rasterization, and the Mac's native materials can differ.
The portable default uses an opaque dark backing rather than emulating native glass
with a web blur. The native macOS implementation retains its own appearance/theme
controls. This contract does not imply portable theme-import or feature parity.

## Verification

`desktop/e2e/smoke.mjs` launches the real release binary on Windows and Linux.
It measures sidebar width, terminal inset/corners, toolbar absence, tile-header
height and grid spacing, and verifies both bundled fonts loaded. It also runs
actual shell commands after menu/dialog transitions, sidebar collapse, canvas
movement, and session restoration. Screenshot evidence is captured on both target
operating systems. See [the verification record](quality-verification.md).
The [rounded-surface refinement](rounded-interface-verification.md) records the
follow-up comparison and clean, real-shell previews.

The native app was compared through its actual macOS interface. Automated VM
checks establish the listed interactions and layout geometry; they are not
physical-device input latency, complete accessibility, IME, or feature-parity
certification.

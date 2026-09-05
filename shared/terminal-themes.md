# Shared terminal colors

`terminal-themes.json` is generated from the native app's existing
`Vendor/GhosttyKit/Sources/GhosttyTheme/Themes` Swift definitions. It preserves
the native catalog order, names, background, foreground, cursor, selection and
all 16 ANSI palette indices. The portable renderer does not currently expose
separate cursor-text or selection-foreground colors.

Run `python3 scripts/generate-portable-themes.py` after updating the native
catalog. Run it with `--check` to verify that the checked-in portable copy
matches the native sources. The generator requires no network access and
fails if a declaration, palette or catalog entry cannot be represented.

The original data is from [iTerm2-Color-Schemes](https://github.com/mbadolato/iTerm2-Color-Schemes),
Copyright 2011-present Mark Badolato, under the MIT license supplied with the
native dependency. The exact notice is included in
`desktop/public/themes/LICENSE.txt` and copied into the portable application's
frontend assets. `terminal-themes-source.json` records the SHA-256 of every
input source file and the license after normalizing line endings to LF,
making the checked-in data reproducible on Windows, Linux and macOS.

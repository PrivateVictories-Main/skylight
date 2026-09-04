# One preset, different operating systems

A named launch preset can now hold a complete configuration for macOS, Windows,
and Linux, while keeping shared defaults for any platform without a custom entry.
The workspace stays visually quiet: these settings appear only when editing a
preset.

- macOS: open **New**, right-click a saved preset, and choose **Edit Preset…**.
- Windows/Linux: open **New**, then use the preset's **⋯** button.
- Choose **Settings for → Defaults / macOS / Windows / Linux**.
- Enable **Use custom settings** for an operating system, then set its shell or
  AI CLI, working folder, and arguments. Save once when finished.
- Disable custom settings to return that operating system to the defaults.

Changing the selected operating system keeps the other draft entries. Cancel
leaves the saved preset untouched. Saving settings never launches a terminal and
does not change already-running sessions.

New-dialog launch, workspace search, and native macOS canvas launch resolve the
current operating system's configuration. Search uses the resolved CLI and folder;
it does not index arguments or other operating systems' folders.

## Interchange

Native preset arrays and portable version-2 workspaces retain the optional
`platformSpecs` map. Keys are `macos`, `windows`, and `linux`. Each value is a
**complete** `TerminalSpec`, not a field-by-field patch: an empty arguments array
clears default arguments, and a null harness selects a regular shell. Missing
platform entries use `spec` as before. Existing preset files remain readable.

See [the shared fixture](../shared/fixtures/platform-presets.json) for a full
example. Other platform entries survive edits, imports, exports, and workspace
saves. Importing presets does not start processes; imported native presets get
fresh IDs so existing presets are not replaced.

Use **File → Export/Import Launch Presets…** on macOS and the workspace menu's
**Export/Import workspace** on Windows/Linux. This transfers configuration only;
there is no cloud sync, credential transfer, or live session migration. Installed
CLIs continue to own their authentication and subscription state on each computer.
Paths are explicit and are not expanded as shell commands.

Use updated Skylight versions on both ends: older applications ignore the optional
map and may discard it on export. OS-level settings still need adjustment when two
computers running the same OS have different folder layouts; machine-specific
profiles are not implemented in this pass.

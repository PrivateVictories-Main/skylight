# Shared Skylight contracts

`cli-catalog.json` fixes the user-facing CLI identifiers and names across the
native Mac application and portable preview. A Swift conformance test detects
catalog drift. Provider support still requires validation on each target OS.

`fixtures/workspace-v2.json` is consumed by Swift, Rust, and TypeScript tests.
CoreGraphics points/sizes are JSON pairs; tile references use `itemID` exactly,
not `itemId`. Dock rails stay intact even when a frontend cannot yet display
native-style edge rails. Unknown fields are preserved by the portable codec.

Native `presets.json` is an array of `{id, name, spec}` objects. Portable workspace
exports carry the same objects in `launchPresets`. Both importers accept the
native preset array; the native importer also reads that workspace field.

A shared preset is a launch recipe. No CLI credential store, authenticated
session, or provider entitlement is imported. Explicit argument values remain part
of the recipe; do not put secrets in those values. Local folder/executable paths must be reviewed
on another OS. Importing a file does not start terminal processes.

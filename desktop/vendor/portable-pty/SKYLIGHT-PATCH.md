# portable-pty 0.9.0 provenance

Source: the published crates.io `portable-pty` 0.9.0 package, from
<https://github.com/wezterm/wezterm>. Original MIT license retained in LICENSE.md.
Cargo.toml, Cargo.toml.orig, src/, and examples/ were copied from that package.

Skylight's only source change removes PSEUDOCONSOLE_INHERIT_CURSOR in
src/win/psuedocon.rs. New Skylight terminal surfaces start with their own cursor;
they do not inherit a parent console. The upstream flag requires an asynchronous
cursor-position reply before further ConPTY operations. The initial Windows CI
run stalled in both real PTY tests with no renderer available to answer it.

Microsoft documents the response requirement and hang condition here:
<https://learn.microsoft.com/en-us/windows/console/createpseudoconsole#remarks>.
The existing resize and input-mode flags remain unchanged.

The workspace patch pins this change for reproducible builds. On upgrading the
dependency, review the flags again and run the real Windows PTY tests, including
startup, resize, input, batch-wrapper arguments, and exit. Do not remove or skip
those tests to make a package build pass.

# Session recovery and keyboard launch

Skylight keeps its regular terminal surface minimal. Recovery controls appear
only when an existing session keeper cannot attach.

## macOS session keeper

- A compatible keeper reconnects normally, preserving its sessions.
- An incompatible protocol leaves the keeper untouched. Use a compatible app
  build to reconnect, or finish its sessions in the previous build first.
- If another Skylight app owns the workspace, close that app and select
  **Retry Connection**. The new app reconnects to the same keeper.
- If an existing keeper does not finish its handshake, Skylight offers retry
  rather than silently creating replacement shells with the same workspace IDs.
- An unavailable keeper binary still permits the existing direct-process
  fallback. Sessions in that fallback do not survive app exit.

Retry requests coalesce and cannot swap the backend beneath open terminals.
The terminal that requested recovery regains keyboard focus when it appears.
This does not add cross-version protocol translation or an automatic keeper
upgrade while sessions are running.

## Launch a saved setup from search

Press **Command-P** on macOS or **Ctrl-Shift-P** in the Windows/Linux preview,
then search for the preset name, CLI, or project folder. A result marked
**Launch preset** creates a fresh session; an existing terminal result opens
that session. For example, search `launch project` to find saved project setups.
Arguments are not included in the search index.

## Windows terminal lifecycle

The portable runtime keeps input, output, and process-exit handling independent.
On Windows, process exit triggers pseudoconsole closure while the output worker
continues draining final bytes; output EOF no longer has to precede process-exit
detection. Explicit close still unblocks the per-session output budget.

The pinned portable-pty dependency has one documented patch: fresh terminal
surfaces do not request the parent console's cursor position. That negotiation
requires a renderer response during startup and previously stalled Windows
startup/resize. See `desktop/vendor/portable-pty/SKYLIGHT-PATCH.md`.

Microsoft's contracts: [cursor negotiation](https://learn.microsoft.com/en-us/windows/console/createpseudoconsole#remarks)
and [pseudoconsole shutdown](https://learn.microsoft.com/en-us/windows/console/closepseudoconsole#remarks).

The Windows tests cover real shell input, resize, exit codes, batch-wrapper
arguments, and closing a quiet shell. CI bounds the runtime-test step so a
regression fails instead of hanging indefinitely. Passing CI does not replace
interactive Windows/Linux hardware, accessibility, IME, and provider testing.

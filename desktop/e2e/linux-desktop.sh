#!/bin/sh
set -eu
# Give GTK a real window manager and session bus within the disposable VM.
mkdir -p e2e/results
openbox > e2e/results/window-manager.log 2>&1 &
window_manager_pid=$!
trap 'kill "$window_manager_pid" 2>/dev/null || true' EXIT INT TERM
node e2e/smoke.mjs

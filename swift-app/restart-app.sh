#!/bin/bash
# Restart ONLY the GUI — never the session daemon.
#
# goty-sessiond lives BESIDE the GUI binary (Goty.app/Contents/MacOS/
# goty-sessiond), so a substring pkill pattern like "MacOS/goty"
# matches BOTH command lines and kills the daemon with every local
# session (2026-08-25: exactly that mistake reset all local tabs —
# fresh shells, scrollback gone; the daemon's PTY children die with
# it and nothing can bring them back).
# The anchored pattern below matches the GUI only: its argv ENDS at
# "goty", while the daemon's argv continues with the socket path.
# `open Goty.app` is NOT sufficiently specific when another checkout
# has the same development CFBundleIdentifier: LaunchServices can bring
# that stale bundle forward instead. `-n` launches this exact path.
set -e
cd "$(dirname "$0")"
pkill -f "Goty.app/Contents/MacOS/goty$" || true
sleep 1
open -n "$(pwd)/Goty.app"

#!/bin/bash
# Watchdog wrapper for headless test binaries: a wedged test holds REAL
# windows on the user's screen, so each run gets a hard timeout — but
# the wrapper must preserve the child's exit status through set -e
# callers and ALWAYS reap its watchdog (the old inline run_guarded died
# at a failing `wait` under set -e before killing it, leaking sleep
# processes and per-run build dirs).
set -u

timeout_seconds=$1
shift
child_pid=""
watchdog_pid=""

cleanup() {
    local status=$?
    trap - EXIT HUP INT TERM
    if [ -n "$watchdog_pid" ]; then
        kill "$watchdog_pid" 2>/dev/null || true
        wait "$watchdog_pid" 2>/dev/null || true
    fi
    if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
        kill "$child_pid" 2>/dev/null || true
        wait "$child_pid" 2>/dev/null || true
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

"$@" &
child_pid=$!
( sleep "$timeout_seconds" && kill -9 "$child_pid" 2>/dev/null ) >/dev/null 2>&1 &
watchdog_pid=$!

if wait "$child_pid"; then
    child_status=0
else
    child_status=$?
fi
exit "$child_status"

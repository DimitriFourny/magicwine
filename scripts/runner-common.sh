#!/bin/bash
# Shared helpers for the real-Wine runners (scripts/test-*.sh); source, do not execute.

# Seconds allowed for each Wine/CLI step; a hung step fails the runner instead of blocking forever.
# shellcheck disable=SC2034 # used by the runners that source this file
STEP_TIMEOUT="${MAGICWINE_TEST_TIMEOUT:-300}"

# run_with_timeout SECONDS COMMAND [ARGUMENT…]
# macOS has no timeout(1); perl is part of the base system. SIGALRM ends the command
# (status 142). Only the command itself is signalled, so callers still stop wineserver.
run_with_timeout() {
    local seconds="$1" status=0
    shift
    perl -e 'alarm shift @ARGV; exec @ARGV or die "exec $ARGV[0]: $!\n"' "$seconds" "$@" || status=$?
    if [[ "$status" -eq 142 ]]; then
        echo "Timed out after ${seconds}s: $*" >&2
    fi
    return "$status"
}

# wineserver_stop WINESERVER
# Stops the server of the exported WINEPREFIX and waits until it has exited, so the prefix
# directory is never removed while Wine is still writing to it.
wineserver_stop() {
    run_with_timeout 30 "$1" -k || true
    run_with_timeout 60 "$1" -w || true
}

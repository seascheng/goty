#!/bin/bash
# Release-mode replay benchmark for the shared agent JSON-RPC channel.
# Builds only the splitter + channel + bench entry point, in an isolated
# temporary directory that is removed on every exit path.
set -euo pipefail
cd "$(dirname "$0")"

BENCH_DIR=$(mktemp -d /private/tmp/goty-agentbench.XXXXXX)
cleanup() {
    local status=$?
    rm -rf -- "$BENCH_DIR"
    exit "$status"
}
trap cleanup EXIT

swiftc -O \
    Sources/Core/Agent/NdjsonSplitter.swift \
    Sources/Core/Agent/JSONRPCChannel.swift \
    tools/agentbench.swift \
    -o "$BENCH_DIR/agentbench"
"$BENCH_DIR/agentbench"

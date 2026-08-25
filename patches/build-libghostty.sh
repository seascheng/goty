#!/bin/bash
# Build libghostty.dylib from the local ghostty-1.3.1 source for goty.
#
# Prereqs:
#   - ghostty v1.3.1 source at $GHOSTTY_SRC (default: sibling of goty)
#   - zig 0.15.2 on PATH (or at $ZIG)
#   - xcrun shim at /tmp/xcrun-shim/xcrun redirecting --show-sdk-path to the
#     macOS 15.4 SDK (zig <=0.15.2 lld cannot parse macOS 26 tbd format;
#     Ghostty officially builds against stable SDKs)
#   - Metal Toolchain: xcodebuild -downloadComponent MetalToolchain
#
# Patches applied to ghostty-1.3.1 (see patches/):
#   1. build.zig: install libghostty dylib+a on Darwin (not just xcframework)
#   2. src/build/GhosttyLib.zig: link Metal/MetalKit frameworks into the
#      shared lib so it builds standalone

set -e
GOTY_GUI="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY_SRC="${GHOSTTY_SRC:-$(dirname "$GOTY_GUI")/ghostty-1.3.1}"
ZIG="${ZIG:-zig}"

export PATH="/tmp/xcrun-shim:$PATH"

cd "$GHOSTTY_SRC"
"$ZIG" build -Doptimize=ReleaseFast -Dapp-runtime=none

mkdir -p "$GOTY_GUI/swift-app/CGhostty/lib"
cp zig-out/lib/libghostty.dylib "$GOTY_GUI/swift-app/CGhostty/lib/"
cp include/ghostty.h include/module.modulemap "$GOTY_GUI/swift-app/CGhostty/include/"

echo "libghostty installed to swift-app/CGhostty/lib/"

#!/bin/bash
# GUI-only rebuild: sessiond is skipped (a parallel agent's uncommitted
# half-done pane.rs breaks cargo; the app already bundles a good
# sessiond). Reuses the packaged bundle's non-GUI parts in place.
set -euo pipefail
cd "$(dirname "$0")/.."
B=/tmp/goty-build-guionly
rm -rf "$B"; mkdir -p "$B"

CMARK_DIR=vendor-c/cmark-gfm/src
CMARK_EXT=vendor-c/cmark-gfm/extensions
mkdir -p "$B"/cmark-objs
for c in "$CMARK_DIR"/*.c "$CMARK_EXT"/*.c; do
    cc -c -O2 -I"$CMARK_DIR" -I"$CMARK_EXT" "$c" \
       -o "$B"/cmark-objs/"$(basename "$c" .c)".o
done
libtool -static -o "$B"/libcmark_gfm.a "$B"/cmark-objs/*.o

SWIFT_SOURCES=$(find vendor-swift -name '*.swift' | grep -v UIKit | grep -v InspectorView | grep -v GrabHandle | grep -v 'GhosttyPackage\.swift')
SWIFT_SOURCES="$SWIFT_SOURCES $(find Sources -name '*.swift' | sort)"

swiftc \
    -parse-as-library -enable-bare-slash-regex \
    $SWIFT_SOURCES \
    -Xcc -fmodule-map-file=CGhostty/include/module.modulemap \
    -Xcc -fmodule-map-file=vendor-c/cmark-gfm/src/module.modulemap \
    -Xcc -ICGhostty/include \
    -Xcc -Ivendor-c/cmark-gfm/src -Xcc -Ivendor-c/cmark-gfm/extensions \
    "$B"/libcmark_gfm.a \
    -L CGhostty/lib -lghostty \
    -Xlinker -rpath -Xlinker @executable_path/CGhostty/lib \
    -F vendor-sparkle -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -framework Metal -framework MetalKit -framework CoreVideo \
    -framework QuartzCore -framework UserNotifications \
    -framework UniformTypeIdentifiers -framework ServiceManagement \
    -framework Security \
    -o "$B"/goty

APP="Goty.app"
cp "$B"/goty "$APP/Contents/MacOS/goty"
cp -R agent-web/dist/ "$APP/Contents/Resources/agent-web/"
codesign --force -s - "$APP" >/dev/null 2>&1
echo "GUI-only rebuild OK: $(date +%H:%M:%S)"

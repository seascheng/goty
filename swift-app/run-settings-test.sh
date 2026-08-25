#!/bin/bash
# Build & run ONE headless suite with the real app sources (the files
# suite's pre-existing failures abort run-tests.sh early, so targeted
# runs need their own entry).
# Usage: swift-app/run-settings-test.sh [entry-file] [name]
#   default entry: tools/settingstest.swift -> settings-test
set -e
cd "$(dirname "$0")"
ENTRY="${1:-tools/settingstest.swift}"
NAME="${2:-settings-test}"

B=/tmp/goty-settings-verify
mkdir -p "$B"

if [ ! -f "$B"/libcmark_gfm.a ] || [ ! -f "$B"/libtreesitter.a ]; then
  CMARK_DIR=vendor-c/cmark-gfm/src
  CMARK_EXT=vendor-c/cmark-gfm/extensions
  mkdir -p "$B"/cmark-objs
  for c in "$CMARK_DIR"/*.c "$CMARK_EXT"/*.c; do
    clang -c -O2 -DCMARK_STATIC_DEFINE=1 "$c" -I"$CMARK_DIR" -o "$B"/cmark-objs/$(basename "$c" .c).o
  done
  ar rcs "$B"/libcmark_gfm.a "$B"/cmark-objs/*.o

  TS_DIR=vendor-c/tree-sitter
  mkdir -p "$B"/ts-objs
  clang -c -O2 "$TS_DIR/src/lib.c" -I"$TS_DIR/src" -I"$TS_DIR/include" -o "$B"/ts-objs/ts_lib.o
  for g in vendor-c/grammars/*/; do
    name=$(basename "$g")
    for c in "$g"parser.c "$g"scanner.c "$g"schema.*.c; do
      [ -f "$c" ] || continue
      clang -c -O2 "$c" -I"$g" -I"$g"tree_sitter -I"$TS_DIR/src" -I"$g/common" \
        -o "$B"/ts-objs/${name}_$(basename "$c" .c).o
    done
  done
  ar rcs "$B"/libtreesitter.a "$B"/ts-objs/*.o
fi

VENDORED=$(find vendor-swift -name '*.swift' | grep -v UIKit | grep -v InspectorView | grep -v GrabHandle | grep -v 'GhosttyPackage\.swift')
STUB_DIR=$(mktemp -d)
sed 's/^@main$//' Sources/App/AppDelegate.swift > "$STUB_DIR/AppDelegate.swift"
SWIFT_SOURCES=$(find Sources -name '*.swift' ! -name 'AppDelegate.swift'; echo "$STUB_DIR/AppDelegate.swift")

swiftc -parse-as-library -enable-bare-slash-regex \
    $VENDORED $SWIFT_SOURCES "$ENTRY" \
    -Xcc -fmodule-map-file=CGhostty/include/module.modulemap \
    -Xcc -fmodule-map-file=vendor-c/cmark-gfm/src/module.modulemap \
    -Xcc -fmodule-map-file=vendor-c/tree-sitter/include/module.modulemap \
    -Xcc -Ivendor-c/tree-sitter/include \
    -Xcc -Ivendor-c/cmark-gfm/src -Xcc -Ivendor-c/cmark-gfm/extensions \
    "$B"/libcmark_gfm.a "$B"/libtreesitter.a \
    -Xcc -ICGhostty/include \
    -L CGhostty/lib -lghostty \
    -Xlinker -rpath -Xlinker @executable_path/CGhostty/lib \
    -framework AppKit -framework Metal -framework MetalKit -framework CoreVideo \
    -framework QuartzCore -framework UserNotifications -framework UniformTypeIdentifiers \
    -framework ServiceManagement \
    -o "$B"/"$NAME"

cp -R CGhostty "$B"/ 2>/dev/null || true
"$B"/"$NAME"

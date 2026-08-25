#!/bin/bash
# Headless layout + logic tests: compiles the app sources with the test
# harness entry point and runs it. The vendored Ghostty sources
# reference the AppDelegate TYPE, so a copy with @main stripped is
# compiled — the type is present, LayoutTest provides the entry point.
# Usage: swift-app/run-tests.sh
set -e
cd "$(dirname "$0")"

# Per-build scratch dir: concurrent sessions raced on shared /tmp
# artifact paths ("input file was modified during the build").
B="/tmp/goty-build-$$"
mkdir -p "$B"

# cmark-gfm static lib (same as build.sh)
CMARK_DIR=vendor-c/cmark-gfm/src
CMARK_EXT=vendor-c/cmark-gfm/extensions
rm -rf "$B"/cmark-objs && mkdir -p "$B"/cmark-objs
for c in "$CMARK_DIR"/*.c "$CMARK_EXT"/*.c; do
    clang -c -O2 -DCMARK_STATIC_DEFINE=1 "$c" -I"$CMARK_DIR" -o "$B"/cmark-objs/$(basename "$c" .c).o
done
ar rcs "$B"/libcmark_gfm.a "$B"/cmark-objs/*.o

# tree-sitter (same step as build.sh).
TS_DIR=vendor-c/tree-sitter
rm -rf "$B"/ts-objs && mkdir -p "$B"/ts-objs
# lib.c is the single-file amalgamation of the whole runtime — compile
# IT ONLY (building the individual .c files too duplicates every symbol).
clang -c -O2 "$TS_DIR/src/lib.c" -I"$TS_DIR/src" -I"$TS_DIR/include" \
    -o "$B"/ts-objs/ts_lib.o
for g in vendor-c/grammars/*/; do
    name=$(basename "$g")
    for c in "$g"parser.c "$g"scanner.c "$g"schema.*.c; do
        [ -f "$c" ] || continue
        clang -c -O2 "$c" -I"$g" -I"$g"tree_sitter -I"$TS_DIR/src" -I"$g/common" \
            -o "$B"/ts-objs/${name}_$(basename "$c" .c).o
    done
done
rm -f "$B"/libtreesitter.a && ar rcs "$B"/libtreesitter.a "$B"/ts-objs/*.o
mkdir -p "$B"/ts-queries
for g in vendor-c/grammars/*/; do
    name=$(basename "$g")
    [ -f "$g/queries/highlights.scm" ] && \
        cp "$g/queries/highlights.scm" "$B"/ts-queries/$name.scm
done

VENDORED=$(find vendor-swift -name '*.swift' | grep -v UIKit | grep -v InspectorView | grep -v GrabHandle | grep -v 'GhosttyPackage\.swift')
STUB_DIR=$(mktemp -d)
sed 's/^@main$//' Sources/App/AppDelegate.swift > "$STUB_DIR/AppDelegate.swift"
SWIFT_SOURCES=$(find Sources -name '*.swift' ! -name 'AppDelegate.swift'; echo "$STUB_DIR/AppDelegate.swift")

swiftc -parse-as-library \
    -enable-bare-slash-regex \
    $VENDORED \
    $SWIFT_SOURCES \
    tools/layouttest.swift \
    -Xcc -fmodule-map-file=CGhostty/include/module.modulemap \
    -Xcc -fmodule-map-file=vendor-c/cmark-gfm/src/module.modulemap \
    -Xcc -fmodule-map-file=vendor-c/tree-sitter/include/module.modulemap \
    -Xcc -Ivendor-c/tree-sitter/include \
    -Xcc -Ivendor-c/cmark-gfm/src -Xcc -Ivendor-c/cmark-gfm/extensions \
    "$B"/libcmark_gfm.a \
    "$B"/libtreesitter.a \
    -Xcc -ICGhostty/include \
    -L CGhostty/lib -lghostty \
    -Xlinker -rpath -Xlinker @executable_path/CGhostty/lib \
    -framework AppKit -framework Metal -framework MetalKit -framework CoreVideo \
    -framework QuartzCore -framework UserNotifications -framework UniformTypeIdentifiers \
    -framework ServiceManagement \
    -o "$B"/goty-layout-test

# The binary links libghostty at @executable_path; give it the real tree.
cp -R CGhostty "$B"/CGhostty 2>/dev/null || true
# Watchdog: a wedged test binary holds REAL windows on the user's
# screen (2026-08-24: a SIGPIPE-muted goty-files-test left one up).
# Tests finish in seconds; five minutes means it never will.
run_guarded() {
    "$@" &
    local pid=$!
    ( sleep 300 && kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 &
    local wd=$!
    wait "$pid"; local st=$?
    kill "$wd" 2>/dev/null
    wait "$wd" 2>/dev/null || true
    return $st
}

run_guarded "$B"/goty-layout-test
# Files-tab behavior suite (creation flow): same source set, second
# entry point.
swiftc -parse-as-library \
     -enable-bare-slash-regex \
     $VENDORED \
     $SWIFT_SOURCES \
     tools/filestest.swift \
     -Xcc -fmodule-map-file=CGhostty/include/module.modulemap \
     -Xcc -fmodule-map-file=vendor-c/cmark-gfm/src/module.modulemap \
    -Xcc -fmodule-map-file=vendor-c/tree-sitter/include/module.modulemap \
    -Xcc -Ivendor-c/tree-sitter/include \
    -Xcc -Ivendor-c/cmark-gfm/src -Xcc -Ivendor-c/cmark-gfm/extensions \
     "$B"/libcmark_gfm.a \
    "$B"/libtreesitter.a \
     -Xcc -ICGhostty/include \
     -L CGhostty/lib -lghostty \
     -Xlinker -rpath -Xlinker @executable_path/CGhostty/lib \
     -framework AppKit -framework Metal -framework MetalKit -framework CoreVideo \
     -framework QuartzCore -framework UserNotifications -framework UniformTypeIdentifiers \
     -framework ServiceManagement \
     -o "$B"/goty-files-test
run_guarded "$B"/goty-files-test

# Settings suite (ghostty-config document + apply pipeline): same
# source set, third entry point.
swiftc -parse-as-library \
     -enable-bare-slash-regex \
     $VENDORED \
     $SWIFT_SOURCES \
     tools/settingstest.swift \
     -Xcc -fmodule-map-file=CGhostty/include/module.modulemap \
     -Xcc -fmodule-map-file=vendor-c/cmark-gfm/src/module.modulemap \
    -Xcc -fmodule-map-file=vendor-c/tree-sitter/include/module.modulemap \
    -Xcc -Ivendor-c/tree-sitter/include \
    -Xcc -Ivendor-c/cmark-gfm/src -Xcc -Ivendor-c/cmark-gfm/extensions \
     "$B"/libcmark_gfm.a \
    "$B"/libtreesitter.a \
     -Xcc -ICGhostty/include \
     -L CGhostty/lib -lghostty \
     -Xlinker -rpath -Xlinker @executable_path/CGhostty/lib \
     -framework AppKit -framework Metal -framework MetalKit -framework CoreVideo \
     -framework QuartzCore -framework UserNotifications -framework UniformTypeIdentifiers \
     -framework ServiceManagement \
     -o "$B"/goty-settings-test
run_guarded "$B"/goty-settings-test

# Core AI types suite: same source set, fourth entry point.
# Security framework linked here for the Keychain calls later tasks add.
swiftc -parse-as-library \
     -enable-bare-slash-regex \
     $VENDORED \
     $SWIFT_SOURCES \
     tools/aitest.swift \
     -Xcc -fmodule-map-file=CGhostty/include/module.modulemap \
     -Xcc -fmodule-map-file=vendor-c/cmark-gfm/src/module.modulemap \
    -Xcc -fmodule-map-file=vendor-c/tree-sitter/include/module.modulemap \
    -Xcc -Ivendor-c/tree-sitter/include \
    -Xcc -Ivendor-c/cmark-gfm/src -Xcc -Ivendor-c/cmark-gfm/extensions \
     "$B"/libcmark_gfm.a \
     "$B"/libtreesitter.a \
     -Xcc -ICGhostty/include \
     -L CGhostty/lib -lghostty \
     -Xlinker -rpath -Xlinker @executable_path/CGhostty/lib \
     -framework AppKit -framework Metal -framework MetalKit -framework CoreVideo \
     -framework QuartzCore -framework UserNotifications -framework UniformTypeIdentifiers \
     -framework ServiceManagement -framework Security \
     -o "$B"/goty-ai-test
run_guarded "$B"/goty-ai-test

#!/bin/bash
# Headless layout + logic tests.
#
# Speed model (2026-08-25 rewrite): the app tree is compiled ONCE into
# a -enable-testing static module (libgoty-test.a + goty.swiftmodule);
# each tool entry point is its own tiny compile+link against it. The
# cmark/tree-sitter archives and the Swift module are cached in a
# content-keyed shared dir — unchanged sources reuse the cache, so a
# rerun costs seconds, not minutes. (The previous script compiled the
# whole tree four times, once per test binary.)
#
# The vendored Ghostty sources reference the AppDelegate TYPE, so a
# copy with @main stripped is compiled — the type is present, the
# tools provide the entry points.
# Usage: swift-app/run-tests.sh
set -e
cd "$(dirname "$0")"

B="/tmp/goty-build-$$"          # per-run binaries (rpath CGhostty copy)
mkdir -p "$B"
CACHE=/tmp/goty-test-cache-$(id -u)
STAMP="$CACHE/.stamp"

CLANG_CC="-O2"
CMARK_DIR=vendor-c/cmark-gfm/src
CMARK_EXT=vendor-c/cmark-gfm/extensions
TS_DIR=vendor-c/tree-sitter

# — cache validity: any input newer than the stamp forces a rebuild —
needs_build() {
    [ -f "$STAMP" ] || return 0
    [ -n "$(find vendor-c vendor-swift Sources -type f -newer "$STAMP" -print -quit 2>/dev/null)" ]
}

# Build into a private staging dir, then swap in atomically — two
# concurrent sessions never race on the shared cache paths.
if needs_build; then
    STAGE=$(mktemp -d "${CACHE}.XXXXXX")
    mkdir -p "$STAGE"

    # cmark-gfm static lib (same flags as build.sh)
    mkdir -p "$STAGE/cmark-objs"
    for c in "$CMARK_DIR"/*.c "$CMARK_EXT"/*.c; do
        clang -c $CLANG_CC -DCMARK_STATIC_DEFINE=1 "$c" -I"$CMARK_DIR" \
            -o "$STAGE"/cmark-objs/$(basename "$c" .c).o
    done
    ar rcs "$STAGE"/libcmark_gfm.a "$STAGE"/cmark-objs/*.o

    # tree-sitter (lib.c is the single-file amalgamation — compile IT
    # ONLY; the individual .c files duplicate every symbol).
    mkdir -p "$STAGE"/ts-objs
    clang -c $CLANG_CC "$TS_DIR/src/lib.c" -I"$TS_DIR/src" -I"$TS_DIR/include" \
        -o "$STAGE"/ts-objs/ts_lib.o
    for g in vendor-c/grammars/*/; do
        name=$(basename "$g")
        for c in "$g"parser.c "$g"scanner.c "$g"schema.*.c; do
            [ -f "$c" ] || continue
            clang -c $CLANG_CC "$c" -I"$g" -I"$g"tree_sitter -I"$TS_DIR/src" -I"$g/common" \
                -o "$STAGE"/ts-objs/${name}_$(basename "$c" .c).o
        done
    done
    ar rcs "$STAGE"/libtreesitter.a "$STAGE"/ts-objs/*.o
    mkdir -p "$STAGE"/ts-queries
    for g in vendor-c/grammars/*/; do
        name=$(basename "$g")
        [ -f "$g/queries/highlights.scm" ] && \
            cp "$g/queries/highlights.scm" "$STAGE"/ts-queries/$name.scm
    done

    # Swift app module: ALL app sources (+ @main-stripped AppDelegate)
    # into one -enable-testing static archive. Tools use
    # `@testable import goty` — they see internal members exactly as
    # they did when everything compiled as one module.
    VENDORED=$(find vendor-swift -name '*.swift' | grep -v UIKit | grep -v InspectorView | grep -v GrabHandle | grep -v 'GhosttyPackage\.swift')
    STUB_DIR="$STAGE/stub"
    mkdir -p "$STUB_DIR"
    sed 's/^@main$//' Sources/App/AppDelegate.swift > "$STUB_DIR/AppDelegate.swift"
    SWIFT_SOURCES=$(find Sources -name '*.swift' ! -name 'AppDelegate.swift'; echo "$STUB_DIR/AppDelegate.swift")

    swiftc -parse-as-library \
        -enable-bare-slash-regex \
        -enable-testing \
        -module-name goty \
        -emit-library -static \
        -emit-module-path "$STAGE"/goty.swiftmodule \
        $VENDORED \
        $SWIFT_SOURCES \
        -Xcc -fmodule-map-file=CGhostty/include/module.modulemap \
        -Xcc -fmodule-map-file=vendor-c/cmark-gfm/src/module.modulemap \
        -Xcc -fmodule-map-file=vendor-c/tree-sitter/include/module.modulemap \
        -Xcc -Ivendor-c/tree-sitter/include \
        -Xcc -Ivendor-c/cmark-gfm/src -Xcc -Ivendor-c/cmark-gfm/extensions \
        -Xcc -ICGhostty/include \
        -o "$STAGE"/libgoty-test.a

    rm -rf "$STAGE"/cmark-objs "$STAGE"/ts-objs "$STAGE"/stub
    mkdir -p "$CACHE"
    OLD=$(mktemp -d "${CACHE}.old.XXXXXX")
    # Swap: stash any previous cache, move the new one in, drop the old.
    for f in libcmark_gfm.a libtreesitter.a libgoty-test.a goty.swiftmodule ts-queries; do
        [ -e "$CACHE/$f" ] && mv "$CACHE/$f" "$OLD/"
        mv "$STAGE/$f" "$CACHE/$f"
    done
    rm -rf "$STAGE" "$OLD"
    touch "$STAMP"
    echo "[run-tests] cache rebuilt (app sources compiled once)"
else
    echo "[run-tests] cache hit — skipping cmark/tree-sitter/app compile"
fi

# Shared compile/link flags for the tool entry points.
CC_FLAGS=(
    -Xcc -fmodule-map-file=CGhostty/include/module.modulemap
    -Xcc -fmodule-map-file=vendor-c/cmark-gfm/src/module.modulemap
    -Xcc -fmodule-map-file=vendor-c/tree-sitter/include/module.modulemap
    -Xcc -Ivendor-c/tree-sitter/include
    -Xcc -Ivendor-c/cmark-gfm/src -Xcc -Ivendor-c/cmark-gfm/extensions
    -Xcc -ICGhostty/include
    -I "$CACHE"
)
LINK_FLAGS=(
    "$CACHE"/libgoty-test.a
    "$CACHE"/libcmark_gfm.a
    "$CACHE"/libtreesitter.a
    -L CGhostty/lib -lghostty
    -Xlinker -rpath -Xlinker @executable_path/CGhostty/lib
    -framework AppKit -framework Metal -framework MetalKit -framework CoreVideo
    -framework QuartzCore -framework UserNotifications -framework UniformTypeIdentifiers
    -framework ServiceManagement -framework Security
)

# The binaries link libghostty at @executable_path; give them the real tree.
cp -R CGhostty "$B"/CGhostty 2>/dev/null || true

# Watchdog: a wedged test binary holds REAL windows on the user's
# screen (2026-08-24: a SIGPIPE-muted goty-files-test left one up).
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

# All four entry points compile+link in parallel (each is one file);
# they only share the read-only cache archive.
FAILED=""
for t in layouttest filestest settingstest aitest; do
    if ! swiftc -parse-as-library -enable-bare-slash-regex \
            tools/$t.swift "${CC_FLAGS[@]}" "${LINK_FLAGS[@]}" \
            -o "$B"/goty-$t-test 2>"$B/$t.err"; then
        cat "$B/$t.err" >&2
        FAILED="$FAILED $t"
    fi
done
[ -z "$FAILED" ] || { echo "test binary compile failed for:$FAILED" >&2; exit 1; }

# Tests run sequentially (they share UserDefaults and real windows).
run_guarded "$B"/goty-layouttest-test
run_guarded "$B"/goty-filestest-test
run_guarded "$B"/goty-settingstest-test
run_guarded "$B"/goty-aitest-test

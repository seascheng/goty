#!/bin/bash
# Build goty (Swift shell + libghostty static lib).
set -e
cd "$(dirname "$0")"

# Per-build scratch dir: concurrent sessions building at the same time
# raced on the shared /tmp artifact paths ("input file was modified
# during the build") — every build owns its own tree.
B="/tmp/goty-build-$$"
mkdir -p "$B"

# Persistent PTY owner. Built first and bundled beside the GUI executable;
# quitting the GUI deliberately leaves this process and its panes alive.
cargo build --release --manifest-path sessiond/Cargo.toml

# Remote workspace server: static musl build (zig cc), uploaded to hosts
# over ssh by RemoteDaemonLink. Config lives in sessiond/.cargo, so build
# from that directory; target config discovery is cwd-based.
(cd sessiond && cargo build --release --target x86_64-unknown-linux-musl)

# Brand icon table is generated from Assets/AgentIcons/*.png. Always
# regenerate: mtime-based skipping missed asset swaps with preserved
# timestamps (stale color icons shipped while Assets held new monochrome
# ones). The generator reads ~30 small PNGs — negligible.
if command -v python3 >/dev/null 2>&1; then
    python3 tools/gen_agent_icons.py
fi

# Sparkle (auto-update): pinned release fetched on demand (gitignored,
# sha256-verified) — module import, link, and the release's EdDSA
# tools (sign_update/generate_keys) all come from this tree.
[ -d vendor-sparkle/Sparkle.framework ] || tools/fetch-sparkle.sh

MAPFILE=CGhostty/include/module.modulemap

# cmark-gfm (vendored CommonMark+GFM engine) → static lib, one file
# per TU; generated headers are committed beside the sources.
CMARK_DIR=vendor-c/cmark-gfm/src
CMARK_EXT=vendor-c/cmark-gfm/extensions
rm -rf "$B"/cmark-objs && mkdir -p "$B"/cmark-objs
for c in "$CMARK_DIR"/*.c "$CMARK_EXT"/*.c; do
    clang -c -O2 -DCMARK_STATIC_DEFINE=1 "$c" -I"$CMARK_DIR" -o "$B"/cmark-objs/$(basename "$c" .c).o
done
ar rcs "$B"/libcmark_gfm.a "$B"/cmark-objs/*.o

SWIFT_SOURCES=$(find vendor-swift -name '*.swift' | grep -v UIKit | grep -v InspectorView | grep -v GrabHandle | grep -v 'GhosttyPackage\.swift')
SWIFT_SOURCES="$SWIFT_SOURCES $(find Sources -name '*.swift' | sort)"

swiftc \
    -parse-as-library -enable-bare-slash-regex \
    $SWIFT_SOURCES \
    -Xcc -fmodule-map-file=$MAPFILE \
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
    -o goty

# Package as a minimal .app bundle: bare binaries crash on AppKit paths
# that need bundleProxyForCurrentProcess (IMK/TSM, clipboard from TUIs).
APP="Goty.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp goty "$APP/Contents/MacOS/goty"
cp sessiond/target/release/goty-sessiond "$APP/Contents/MacOS/goty-sessiond"
cp sessiond/target/x86_64-unknown-linux-musl/release/goty-sessiond \
    "$APP/Contents/Resources/goty-sessiond-linux-x86_64"

# Real file, not a symlink: the macOS 26.5 loader spins forever resolving
# the CGhostty symlink chain (observed 2026-08-21; adhoc + @rpath).
# Ship ONLY the dylib the binary loads (install name .../libghostty-internal.dylib).
# The build tree keeps it as libghostty.dylib + an -internal symlink alias;
# cp -RL dereferenced that into a second byte-identical 18MB copy in the app.
mkdir -p "$APP/Contents/MacOS/CGhostty/lib"
cp CGhostty/lib/libghostty.dylib \
    "$APP/Contents/MacOS/CGhostty/lib/libghostty-internal.dylib"
# Sparkle embedded at Contents/Frameworks (rpath above points here).
cp -R vendor-sparkle/Sparkle.framework "$APP/Contents/Frameworks/"
# App icon (Ghostty-theme ghost, source: Assets/app-logo.png).
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Goty AI</string>
    <key>CFBundleDisplayName</key><string>Goty AI</string>
    <key>CFBundleIdentifier</key><string>com.goty.ai</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleExecutable</key><string>goty</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>SUFeedURL</key><string>https://raw.githubusercontent.com/seascheng/goty/main/appcast.xml</string>
    <key>SUPublicEDKey</key><string>BVEKBLzlYYm5/fdE1kQh1JwSfpzsX414EvnXxGQy6hA=</string>
    <!-- Launcher XPC needs the app and XPC signed by one team — false
         for ad-hoc builds (embedded Autoupdate installs instead);
         release.sh flips it true on the Developer-ID path. -->
    <key>SUEnableInstallerLauncherService</key><false/>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
PLIST

# Ad-hoc sign everything we ship. The linker's automatic adhoc signature
# covers only the bare main binary (Info.plist unbound, resources
# unsealed): macOS TCC could not persist a Downloads-folder grant against
# that broken bundle signature and re-prompted on every access (2026-08-26:
# endless "Goty wants to access files in your Downloads folder" dialogs).
# Nested Mach-O first, then the bundle; the linux-musl ELF is a resource
# uploaded over ssh, never executed on macOS, so it stays unsigned.
codesign --force --sign - --identifier com.goty.ai.sessiond \
    "$APP/Contents/MacOS/goty-sessiond"
codesign --force --sign - --identifier com.goty.ai.libghostty \
    "$APP/Contents/MacOS/CGhostty/lib/libghostty-internal.dylib"
codesign --force --sign - --identifier com.goty.ai "$APP"

echo "built: $(pwd)/goty and $APP"

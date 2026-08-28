#!/bin/bash
# Release pipeline: build → DMG → Sparkle-sign → appcast → push →
# GitHub release.
#
# Signing is automatic by what the keychain holds:
#   • "Developer ID Application" present → deep re-sign the app with
#     that identity + hardened runtime, enable Sparkle's installer
#     launcher XPC, notarize the DMG (xcrun notarytool, stored profile
#     "$NOTARY_PROFILE", default goty-notary) and staple it.
#   • otherwise → ad-hoc (today's mode): the DMG ships unsigned;
#     first open is right-click → Open. Sparkle updates still verify
#     (EdDSA); the embedded Autoupdate installs them
#     (SUEnableInstallerLauncherService=false).
#
# Usage: swift-app/release.sh ["release notes, one bullet per line"]
set -euo pipefail
cd "$(dirname "$0")/.."

APP_BUNDLE="Goty.app"
APP="swift-app/$APP_BUNDLE"
NOTARY_PROFILE="${NOTARY_PROFILE:-goty-notary}"

echo "==> build"
swift-app/build.sh

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "$APP/Contents/Info.plist")
DMG_NAME="Goty-$VERSION-arm64.dmg"
TAG="v$VERSION"
echo "==> releasing $TAG (build $BUILD)"

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/Developer ID Application/ {print $2; exit}' || true)
if [ -n "$IDENTITY" ]; then
    echo "==> Developer ID found — re-signing deep + hardened runtime"
    /usr/libexec/PlistBuddy -c 'Set :SUEnableInstallerLauncherService true' \
        "$APP/Contents/Info.plist"
    codesign --force --sign "$IDENTITY" --identifier com.goty.ai.sessiond \
        "$APP/Contents/MacOS/goty-sessiond"
    codesign --force --sign "$IDENTITY" --identifier com.goty.ai.libghostty \
        --options runtime "$APP/Contents/MacOS/CGhostty/lib/libghostty-internal.dylib"
    codesign --force --sign "$IDENTITY" --options runtime \
        "$APP/Contents/Frameworks/Sparkle.framework"
    codesign --force --sign "$IDENTITY" --identifier com.goty.ai \
        --options runtime "$APP"
else
    echo "==> ad-hoc build (no Developer ID identity in keychain)"
fi

echo "==> DMG"
mkdir -p dist
rm -rf dist/stage && mkdir dist/stage
cp -R "$APP" dist/stage/
rm -f "dist/$DMG_NAME"

# create-dmg drives Finder through AppleScript and flakes now and then;
# a flaked run exits 2 AND leaves its interstitial rw.* image mounted,
# which then breaks the next attempt too (2026-08-28: two consecutive
# v0.1.1 failures, each stranding a volume). Detach any leftover first
# and retry once.
cleanup_interstitial() {
    hdiutil info | awk '
        /^image-path/ { img = $3 }
        /^\/dev\/disk/ && img ~ /\/rw\./ { print $1 }' \
    | while IFS= read -r dev; do
        hdiutil detach "$dev" >/dev/null 2>&1 || true
    done
    rm -f dist/rw.*.dmg 2>/dev/null || true
}

cleanup_interstitial
if ! create-dmg \
    --volname "Goty" \
    --window-pos 200 120 --window-size 660 400 \
    --icon-size 160 \
    --icon "$APP_BUNDLE" 180 170 \
    --app-drop-link 480 170 \
    --hide-extension "$APP_BUNDLE" \
    "dist/$DMG_NAME" dist/stage >/dev/null; then
    echo "  create-dmg flaked — cleaning stale mounts, retrying" >&2
    cleanup_interstitial
    create-dmg \
        --volname "Goty" \
        --window-pos 200 120 --window-size 660 400 \
        --icon-size 160 \
        --icon "$APP_BUNDLE" 180 170 \
        --app-drop-link 480 170 \
        --hide-extension "$APP_BUNDLE" \
        "dist/$DMG_NAME" dist/stage >/dev/null
fi

if [ -n "$IDENTITY" ]; then
    echo "==> notarize + staple"
    if xcrun notarytool submit "dist/$DMG_NAME" \
        --keychain-profile "$NOTARY_PROFILE" --wait; then
        xcrun stapler staple "dist/$DMG_NAME"
    else
        echo "!! notarization failed (profile '$NOTARY_PROFILE'?)" >&2
        exit 1
    fi
fi

echo "==> Sparkle signature"
SIGOUT=$(swift-app/vendor-sparkle/bin/sign_update "dist/$DMG_NAME")
EDSIG=$(printf '%s' "$SIGOUT" | sed -n 's/.*edSignature="\([^"]*\)".*/\1/p')
LENGTH=$(printf '%s' "$SIGOUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')
[ -n "$EDSIG" ] && [ -n "$LENGTH" ] || { echo "sign_update parse failed: $SIGOUT" >&2; exit 1; }

NOTES="${1:-Goty $VERSION.}"
python3 swift-app/tools/update_appcast.py appcast.xml \
    --version "$VERSION" --build "$BUILD" \
    --url "https://github.com/seascheng/goty/releases/download/$TAG/$DMG_NAME" \
    --signature "$EDSIG" --length "$LENGTH" \
    --notes "$NOTES"

echo "==> git"
git add appcast.xml
git commit -m "release: $TAG appcast" || true
git push origin main
git tag -f "$TAG" >/dev/null
git push -f origin "$TAG"


echo "==> GitHub release"
# GitHub turns a bare @ai in the notes into a mention of github.com/ai
# (it then shows as a release "contributor"); the product feature name
# must stay literal — inline-code it.
GH_NOTES=$(printf '%s' "$NOTES" | sed 's/@ai/`@ai`/g')
gh release create "$TAG" "dist/$DMG_NAME" \
    --title "Goty $VERSION" \
    --notes "$GH_NOTES

macOS 13+ · Apple Silicon (arm64). Ad-hoc signed: on first open,
right-click the app → Open (once), or remove the quarantine flag:
\`\`\`
xattr -dr com.apple.quarantine /Applications/Goty.app
\`\`\`"

echo "==> done: dist/$DMG_NAME"

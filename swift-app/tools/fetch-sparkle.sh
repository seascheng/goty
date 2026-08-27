#!/bin/bash
# Fetch the pinned Sparkle release into vendor-sparkle/ (framework +
# generate_keys/sign_update). The tree is gitignored; this script makes
# a clean checkout reproducible (sha256-pinned).
set -e
cd "$(dirname "$0")/.."

VERSION=2.9.6
SHA=52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192

if [ -d vendor-sparkle/Sparkle.framework ] && [ -x vendor-sparkle/bin/sign_update ]; then
    echo "vendor-sparkle: Sparkle $VERSION already present"
    exit 0
fi

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
curl -fsSL -o "$T/Sparkle.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz"
echo "$SHA  $T/Sparkle.tar.xz" | shasum -a 256 --check -

rm -rf vendor-sparkle
mkdir vendor-sparkle
tar -xJf "$T/Sparkle.tar.xz" -C vendor-sparkle
# Keep only what we build against / release with.
cd vendor-sparkle
rm -rf "Sparkle Test App.app" SampleAppcast.xml Symbols INSTALL LICENSE CHANGELOG

echo "vendor-sparkle: Sparkle $VERSION ready"

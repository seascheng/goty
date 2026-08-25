# Ghostty 1.3.1 build patches

Two patches make the full libghostty buildable standalone on macOS:

## 1. `build.zig` — install libghostty on Darwin

Upstream only installs `libghostty.so/.a` on non-Darwin; on macOS it goes
through the xcframework/app-bundle flow. We install the dylib + static lib
directly so a Swift host can link them.

Applied in the tree at `build.zig` (search `GOTY PATCH`).

## 2. `src/build/GhosttyLib.zig` — link Metal frameworks into the dylib

The shared library references Metal symbols (renderer + imgui metal
backend); upstream relies on the app-bundle link step to provide them.
Standalone dylibs need `-framework Metal -framework MetalKit`.

Applied at `src/build/GhosttyLib.zig` (search `GOTY PATCH`).

## 3. Environment (not a patch)

zig <= 0.15.2's lld cannot parse the macOS 26 SDK tbd format (V9), which
drops ALL libSystem symbols at link time. Redirect SDK discovery to the
macOS 15.4 SDK in CommandLineTools with an xcrun shim:

```sh
mkdir -p /tmp/xcrun-shim
cat > /tmp/xcrun-shim/xcrun <<'EOF'
#!/bin/bash
for arg in "$@"; do
    if [ "$arg" = "--show-sdk-path" ]; then
        echo "/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
        exit 0
    fi
done
exec /usr/bin/xcrun "$@"
EOF
chmod +x /tmp/xcrun-shim/xcrun
```

Note: the shim must handle both `--show-sdk-path` and
`--sdk macosx --show-sdk-path` (zig uses the latter).


## 4. Runtime integration (theme/config resolution)

The built dylib has no app runtime: `theme =` resolution needs
`GHOSTTY_RESOURCES_DIR`, captured at `ghostty_init` time. See
`libghostty-integration.md` for the full mechanism, pitfalls, and
verification tooling (Chinese).

See `build-libghostty.sh` for the full build procedure.

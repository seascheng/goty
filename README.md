# Goty

Native macOS terminal app (Swift + AppKit + libghostty VT engine), built on
tty7's architecture: the GUI owns no PTYs — a small Rust daemon does.

- **Servers** — local Mac plus ssh hosts, each an independent session owner
- **Spaces** — session tabs, grouped by working directory (tty7 sidebar model)
- **File manager** — browse/copy on either side of the connection

## Architecture

- `swift-app/Sources/Core` — session daemon client, store, coordinators
- `swift-app/Sources/UI` — AppKit chrome (sidebar, terminal views, panels)
- `swift-app/sessiond` — standalone Rust PTY daemon (`goty-sessiond`);
  owns every local pane and its replay ring
- Remote servers run the same sessiond (musl static build) installed over
  ssh into `~/.local/share/goty/bin/`; one `ssh -N -L` socket forward
  bridges it locally. Sessions survive GUI exit and reconnect with scrollback.
- `swift-app/vendor-swift` — Ghostty surface view vendored from Ghostty.app
- `patches/` — libghostty build patches and script (`swift-app/CGhostty`)

Working principles and architecture invariants: see `CLAUDE.md`.

## Build

```sh
swift-app/build.sh
```

Builds sessiond (native + linux-musl), compiles the Swift app against the
locally built `libghostty` dylib, and packages `swift-app/Goty.app`.

Prerequisite for the GUI link step: `patches/build-libghostty.sh` once per
Ghostty source tree (zig + Metal toolchain required).

## Checks

```sh
cargo fmt --manifest-path swift-app/sessiond/Cargo.toml -- --check
cargo clippy --manifest-path swift-app/sessiond/Cargo.toml --all-targets -- -D warnings
cargo test --manifest-path swift-app/sessiond/Cargo.toml
```

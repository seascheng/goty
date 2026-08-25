# AGENTS.md

## Build

- The product is the Swift app under `swift-app/` (AppKit + libghostty).
  Build everything with `swift-app/build.sh`; it also packages
  `swift-app/Goty.app` and the bundled `goty-sessiond`.
- sessiond is a standalone Cargo workspace at `swift-app/sessiond/Cargo.toml`
  (plus a linux-musl target config). There is no root Cargo workspace.
- The GUI link step needs the locally built `libghostty` dylib under
  `swift-app/CGhostty` — produce it once per Ghostty tree with
  `patches/build-libghostty.sh`.

## Checks

Run before committing:

```sh
cargo fmt --manifest-path swift-app/sessiond/Cargo.toml -- --check
cargo clippy --manifest-path swift-app/sessiond/Cargo.toml --all-targets -- -D warnings
cargo test --manifest-path swift-app/sessiond/Cargo.toml
```

Swift side: `swift-app/build.sh` must succeed; treat new Swift warnings as
errors to fix, not to commit.

## Scope

- This product has no relation to goty: PTYs, sessions, replay, and remote
  distribution are owned by our own `goty-sessiond`. Do not reintroduce a
  goty backend, the old GPUI crate, or any crepuscularity dependency.
- tty7 (`../tty7`) is the design reference for sidebar, tabs,
  grouping, and interaction models; cmux/Warp/Arc are visual references only.
- Long-lived architecture invariants (threading, pane identity, icon rules,
  cache invalidation) live in `CLAUDE.md` and are binding.
- No browser panes, plugin UI, marketplace, cloud accounts, or telemetry.
- Keep UI work in `swift-app/Sources/UI`; keep logic in
  `swift-app/Sources/Core` with zero AppKit view imports.

## Ops: restarting the GUI

- NEVER `pkill -f ".../MacOS/goty"` — the substring also matches
  `goty-sessiond` (same bundle dir) and kills every local session.
  Use `swift-app/restart-app.sh` (anchored pattern, GUI only).

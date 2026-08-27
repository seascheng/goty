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

- The session stack is owned end-to-end by this repo: PTYs, sessions,
  replay, and remote distribution all live in `goty-sessiond`. Do not
  reintroduce the previous backend, the old GPUI crate, or any
  crepuscularity dependency.
- tty7 (the sibling workspace) is the design reference for sidebar, tabs,
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

## Release (build → update → publish)

- One command ships a version: `swift-app/release.sh "notes, one bullet per line"`.
  It builds, packages the DMG (create-dmg), EdDSA-signs it, updates `appcast.xml`
  at the repo root, commits + pushes, re-tags, and creates the GitHub release.
- Bump the version in exactly two places, both in the `Info.plist` heredoc in
  `swift-app/build.sh`: `CFBundleShortVersionString` and `CFBundleVersion`
  (build number — must be unique per release; Sparkle keys updates off it).
- Auto-updates run through Sparkle 2.9.6, pinned (sha256) by
  `swift-app/tools/fetch-sparkle.sh`. `vendor-sparkle/` is fetched on demand
  (build.sh and run-tests.sh auto-fetch) and gitignored. Feed:
  `SUFeedURL` → raw `appcast.xml` on main; `SUPublicEDKey` is baked into the
  same heredoc; the matching EdDSA private key lives in this machine's keychain
  (`vendor-sparkle/bin/sign_update` uses it — never print or commit it).
- Release notes: a bare `@ai` in the GitHub body becomes a mention of
  github.com/ai and renders as a release "contributor" — release.sh escapes it;
  keep the escaping when editing notes by hand.
- Signing follows the keychain automatically: ad-hoc today (first open is
  right-click → Open). Importing a "Developer ID Application" identity switches
  release.sh to deep re-sign + hardened runtime + notarize/staple (store
  notarytool credentials as keychain profile `goty-notary` first).
- github.com over ssh port 22 is hijacked by the local proxy: the origin remote
  is `ssh://git@ssh.github.com:443/seascheng/goty.git` — keep it on 443.
- CI (`.github/workflows/checks.yml`): cargo fmt/clippy/test plus a Swift
  typecheck (Sparkle fetched first) on pushes to main.

# Agent Session Concurrency and Performance Design

Date: 2026-09-14
Status: Draft for written review

## Objective

Make agent sessions deterministic under concurrent transport and UI activity,
remove main-thread stalls from connection and replay work, close leaked RPC
lifetimes, and repair the test runner defects discovered during the audit.

This work covers the shared agent transport path and the Codex, Pi/OMP, and
Claude adapters. It does not change wire protocols, user-visible features,
session persistence formats, pane identity, or daemon ownership.

## Evidence

- `PaneSession` invokes `onFrame` on its detached reader thread.
- `CodexSession`, `PiSession`, and `ClaudeSession` currently mutate adapter
  state directly from that callback while their public API is called by the UI
  on the main thread.
- `PiSession.openPane` performs blocking daemon work on a background queue, but
  also installs `pane`, `connected`, and handshake state on that queue. Codex
  and Claude instead perform some daemon connection work synchronously on the
  main thread.
- `JSONRPCChannel.feed` holds one lock while splitting and parsing all JSON.
  A large replay can therefore block a main-thread `request` on the same lock.
- `JSONRPCChannel` has no operation that fails and removes outstanding requests
  when its transport exits, disconnects, or shuts down.
- The repository's terminal `PaneHost` already uses the desired shape:
  background stream parsing with ordered main-thread state/UI effects.
- Monocode's Codex JSON-RPC client keeps session mutation on one event loop and
  rejects all pending requests when the transport closes.
- `run-tests.sh` exits at a failed `wait` under `set -e` before killing its
  watchdog. It also never removes its per-run directory. The machine currently
  has 441 such directories using about 3.2 GiB.
- The full Swift test suite passes but reports one goty-owned warning:
  `CodexSession.readyEvents` is never mutated.
- `goty-sessiond` passes formatting, Clippy with warnings denied, and all 23
  unit tests.

## Invariants

1. Adapter state is main-thread confined. Public `AgentSessioning` calls,
   request completions, parsed protocol callbacks, connection state changes,
   timers, and delegate emission all observe one ordered execution domain.
2. Socket reads, NDJSON splitting, JSON parsing, filesystem scans, and remote
   daemon connection attempts stay off the main thread.
3. The order of frames from one `PaneSession` is preserved through parsing and
   main-thread delivery, including replay/live boundaries.
4. A connection result from an obsolete connect/reconnect attempt cannot
   install a pane after shutdown or a newer attempt.
5. Every outstanding JSON-RPC request ends exactly once: success, server error,
   transport failure, or shutdown.
6. No callbacks execute while a channel lock is held.
7. Existing pane identity, attach-versus-spawn behavior, replay suppression,
   permission recovery, and session restore semantics remain unchanged.

## Architecture

### Main-thread adapter boundary

`AgentSessioning` and `AgentSessionDelegate` become explicit main-actor
interfaces. Codex, Pi/OMP, and Claude adapters conform on the main actor. This
makes their existing synchronous properties and commands honest: callers never
need locks or synchronous queue hops to read session state.

The compiler annotation is the contract, not just a comment or runtime
assertion. Background closures must cross the boundary explicitly, making a
future accidental state mutation visible during compilation.

### Background parsing, ordered delivery

`JSONRPCChannel` and `LineChannel` remain thread-safe parsing components. Each
accepts an optional callback queue. Production adapters use the main queue;
tests may use immediate delivery when deterministic synchronous behavior is
useful.

For each feed call, the channel:

1. extracts complete lines under a narrow framing lock;
2. releases that lock and parses JSON off-lock on the reader thread;
3. performs only short pending-request/counter/echo-ring operations under a
   separate state lock;
4. creates one ordered callback batch; and
5. delivers that batch on the configured callback queue with no lock held.

One batch per feed avoids a main-queue dispatch for every JSON line while
preserving notification, request, orphan-result, and completion order.

`LineChannel` carries the replay flag with each parsed frame. Pi/OMP derives
replay suppression and mapper replay state from that flag at callback time,
rather than relying on mutable flags wrapped around a formerly synchronous
`feed` call.

Control frames such as `EXITED` and disconnect callbacks cross to the main
actor before touching adapter state. Raw output and snapshot bytes continue to
be parsed away from the main thread.

### Asynchronous daemon connection

Blocking `SessionDaemon.openPaneWithAttachment` calls run on a utility or
user-initiated background queue for all adapters. The result is delivered to
the main actor before adapter state is changed or a handshake begins.

Each adapter owns a monotonically increasing connection generation. Starting
connect, reconnect, or shutdown advances it. A completion installs its pane
only when its captured generation is still current; otherwise it closes the
returned `PaneSession`. This prevents late remote connection results from
resurrecting a stopped or superseded session.

The shared abstraction is limited to asynchronous opening and delivery. Wire
handshakes remain inside each adapter because Codex, Pi/OMP, and Claude have
materially different startup semantics.

### JSON-RPC request lifetime

`JSONRPCChannel` gains a transport-failure operation that atomically removes
all pending completions and then fails them outside the lock. Unlike a terminal
`close`, this operation permits a reconnect to reuse the channel with new
request IDs.

Codex invokes it on process exit, transport disconnect, shutdown, and before a
new transport epoch starts. A completion removed by a normal response cannot
also be failed by teardown.

### Test runner lifecycle

`run-tests.sh` installs an `EXIT` trap immediately after creating its per-run
directory. The trap stops any active watchdog and removes only that exact,
fully resolved directory. It does not touch the shared content-addressed test
cache.

`run_guarded` captures a failing test status through an `if wait` branch so
`set -e` cannot bypass watchdog cleanup. Normal success, test failure, signal,
and early compile failure all converge on the same cleanup path.

Existing `/private/tmp/goty-build-*` directories are not deleted by the code
change. Removing those historical artifacts is a separate explicit operation
because it is destructive, even though they are temporary build outputs.

## Error Handling

- Connection failures return to the main actor and preserve current user-facing
  failure/reconnect behavior.
- Stale connection completions close their newly returned pane silently; they
  do not emit failure events for an obsolete attempt.
- Transport teardown fails pending RPCs with their existing `RPCFailure`
  carrier and a specific transport message.
- Callback scheduling preserves the weak-capture behavior used today, so a
  released adapter is not retained by queued protocol traffic.
- Test cleanup is best-effort and must not replace the original test exit code.

## Testing

Implementation follows TDD in this order:

1. Channel callback-queue test: feed on a background queue, assert callbacks
   arrive on the configured queue and retain wire order.
2. JSON-RPC lifecycle test: register multiple requests, fail the transport,
   assert every completion fails once and the pending count becomes zero.
3. Replay metadata test: asynchronous `LineChannel` delivery retains the
   replay flag and Pi/OMP suppression semantics.
4. Connection-generation test: an older delayed open result cannot replace a
   newer connection or survive shutdown.
5. Adapter execution-domain tests: background frames result in main-thread
   state/delegate updates.
6. A shell-level `run_guarded` failure probe confirms the child status is
   preserved and both watchdog and per-run directory are cleaned.
7. Existing `agenttest`, all Swift headless tests, `goty-sessiond` fmt, Clippy,
   and unit tests remain green.
8. `swift-app/build.sh` succeeds with no new goty-owned Swift warnings.

## Performance Verification

Performance claims are limited to measured or structurally proven effects:

- Record the time for a main-thread request registration while a large replay
  is parsed. After lock separation, registration must not wait for replay JSON
  parsing; the test uses a controlled parser seam rather than a fragile
  machine-speed threshold.
- Record connection setup with an injected delayed opener and verify the main
  queue remains responsive while the delay is in flight.
- Compare a representative large replay before and after using release-mode
  instrumentation. Callback batching must not increase total replay time by
  more than noise and must reduce main-queue callback count to at most one per
  transport feed.
- Do not claim broader CPU or memory improvements without an Instruments or
  benchmark trace showing them.

## Delivery Order

1. Add the replay benchmark/probe and record the unmodified baseline.
2. Add failing channel ordering, lifecycle, and lock-contention tests.
3. Refactor channel locks and callback batching; make pending failure explicit.
4. Add failing connection-generation and main-thread confinement tests.
5. Move adapter state to the main actor and daemon opening off-main.
6. Repair replay metadata handling in Pi/OMP.
7. Fix `run-tests.sh` cleanup and the Codex immutable-variable warning.
8. Run all checks and the performance probes; address only regressions caused
   by this work.

## Non-goals

- No browser panes, plugins, cloud accounts, telemetry, or new UI.
- No wire-format or persisted-state migration.
- No replacement of sessiond, libghostty, or the adapter protocol.
- No broad splitting of large adapter files based only on line count.
- No deletion of historical temporary directories without separate approval.
- No unrelated cleanup of vendored Ghostty warnings.

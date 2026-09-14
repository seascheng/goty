# Agent Session Concurrency and Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Confine agent-session state to the main actor while keeping transport parsing and daemon connection work off-main, eliminate channel lock contention and leaked RPC completions, and make the Swift test runner clean up reliably.

**Architecture:** `JSONRPCChannel` and `LineChannel` split framing from request state, parse off-lock on the pane reader thread, and deliver one ordered callback batch on a configured queue. `AgentSessioning` is a main-actor API; a shared `AgentConnectionGate` opens daemon panes in the background, returns results to the main actor, and rejects stale results using a generation owned by each adapter's gate instance.

**Tech Stack:** Swift/AppKit, Foundation `DispatchQueue`/`NSLock`, Unix shell, Rust/Cargo session daemon, existing headless Swift test tools.

**Spec:** `docs/superpowers/specs/2026-09-14-agent-session-concurrency-performance-design.md`

## Global Constraints

- Keep UI work in `swift-app/Sources/UI`; Core must import no AppKit view types.
- Do not change agent wire formats, persisted state, pane identity, attach-versus-spawn behavior, permission recovery, or replay authority.
- Socket reads, NDJSON splitting, JSON parsing, store scans, and daemon connection attempts stay off the main thread.
- Public adapter state, request completions, timers, connection transitions, and delegate calls are main-actor confined and FIFO ordered.
- No callback may execute while a channel lock is held.
- No browser panes, plugin UI, marketplace, cloud accounts, or telemetry.
- Do not alter the user's existing `README.md` or `swift-app/agent-web/tools/` changes.
- Do not delete historical `/private/tmp/goty-build-*` directories without separate user approval.
- Use `swift-app/restart-app.sh` if runtime verification needs a GUI restart; never use `pkill -f` against the app bundle.

## File Map

- Create `swift-app/tools/agentbench.swift`: release-mode replay throughput probe for the shared JSON-RPC channel.
- Create `swift-app/run-agent-bench.sh`: builds the focused benchmark in an isolated temporary directory and removes it on exit.
- Modify `swift-app/Sources/Core/Agent/JSONRPCChannel.swift`: narrow locks, ordered callback batches, callback queue, parser seam, and pending-request failure.
- Modify `swift-app/Sources/Core/Agent/LineChannel.swift`: narrow locks, ordered callback batches, callback queue, and replay metadata delivery.
- Create `swift-app/Sources/Core/Agent/AgentSessionExecution.swift`: background-work/main-delivery helper and generation-fenced connection gate.
- Modify `swift-app/Sources/Core/Agent/AgentSessioning.swift`: declare the adapter and delegate boundary as `@MainActor`.
- Modify `swift-app/Sources/Core/Agent/AgentRegistry.swift`: make adapter factories main-actor closures.
- Modify `swift-app/Sources/Core/Agent/Adapters/CodexSession.swift`: queued protocol delivery, asynchronous pane opening, stale-result fencing, and JSON-RPC teardown.
- Modify `swift-app/Sources/Core/Agent/Adapters/PiSession.swift`: queued protocol delivery, replay metadata handling, and asynchronous pane opening.
- Modify `swift-app/Sources/Core/Agent/Adapters/ClaudeSession.swift`: queued protocol delivery and asynchronous pane opening.
- Modify `swift-app/Sources/Core/Agent/Adapters/OmpSession.swift`: main-actor annotation for the private probe delegate.
- Modify `swift-app/Sources/UI/Agent/AgentPaneHost.swift`: remove redundant main dispatches once delegate callbacks are actor-isolated.
- Modify `swift-app/Sources/App/AppDelegate.swift`: call the main-actor adapter factory from an explicit main-actor context.
- Modify `swift-app/tools/agenttest.swift`: channel, execution-domain, replay, generation, and teardown contract tests.
- Modify `swift-app/tools/agentprobe.swift`, `compactprobe.swift`, and `replayprobe.swift`: keep standalone probes compatible with the main-actor protocol.
- Create `swift-app/tools/run-guarded.sh`: one-command watchdog wrapper with reliable failure cleanup.
- Modify `swift-app/run-tests.sh`: use the wrapper and always remove its exact per-run directory.

---

### Task 1: Capture the Unmodified Replay Baseline

**Files:**
- Create: `swift-app/tools/agentbench.swift`
- Create: `swift-app/run-agent-bench.sh`

**Interfaces:**
- Consumes: `JSONRPCChannel.feed(_:replay:)`, `JSONRPCChannel.messagesRouted`, and `NdjsonSplitter`.
- Produces: `swift-app/run-agent-bench.sh`, which prints `bytes`, `messages`, `seconds`, and `mib_per_second` for a 16 MiB release-mode replay.

- [ ] **Step 1: Add the focused benchmark entry point**

Create `swift-app/tools/agentbench.swift`:

```swift
import Foundation

@main
enum AgentBench {
    static func main() {
        let line = #"{"jsonrpc":"2.0","method":"item/agentMessage/delta","params":{"delta":"benchmark payload"}}"# + "\n"
        let lineBytes = Array(line.utf8)
        let targetBytes = 16 * 1024 * 1024
        let repetitions = targetBytes / lineBytes.count
        var replay = [UInt8]()
        replay.reserveCapacity(repetitions * lineBytes.count)
        for _ in 0 ..< repetitions {
            replay.append(contentsOf: lineBytes)
        }

        let channel = JSONRPCChannel()
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            channel.feed(replay, replay: true)
        }
        let parts = elapsed.components
        let seconds = Double(parts.seconds)
            + Double(parts.attoseconds) / 1_000_000_000_000_000_000
        let mib = Double(replay.count) / 1_048_576
        let throughput = mib / max(seconds, 0.000_001)

        guard channel.messagesRouted == repetitions else {
            fputs("agentbench: routed \(channel.messagesRouted), expected \(repetitions)\n", stderr)
            exit(1)
        }
        print(String(format: "agentbench bytes=%d messages=%d seconds=%.6f mib_per_second=%.2f",
                     replay.count, repetitions, seconds, throughput))
    }
}
```

- [ ] **Step 2: Add an isolated release-mode runner**

Create `swift-app/run-agent-bench.sh`:

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

BENCH_DIR=$(mktemp -d /private/tmp/goty-agentbench.XXXXXX)
cleanup() {
    local status=$?
    rm -rf -- "$BENCH_DIR"
    exit "$status"
}
trap cleanup EXIT

swiftc -O \
    Sources/Core/Agent/NdjsonSplitter.swift \
    Sources/Core/Agent/JSONRPCChannel.swift \
    tools/agentbench.swift \
    -o "$BENCH_DIR/agentbench"
"$BENCH_DIR/agentbench"
```

Run: `chmod +x swift-app/run-agent-bench.sh`

- [ ] **Step 3: Run the benchmark against the unmodified channel**

Run: `swift-app/run-agent-bench.sh`

Expected: exit 0 and one line beginning `agentbench bytes=`. Preserve the complete output for the final before/after report; do not edit the benchmark parameters between runs.

- [ ] **Step 4: Verify the benchmark leaves no temporary directory**

Run: `find /private/tmp -maxdepth 1 -type d -name 'goty-agentbench.*' -print`

Expected: no output.

- [ ] **Step 5: Commit the benchmark**

```bash
git add swift-app/tools/agentbench.swift swift-app/run-agent-bench.sh
git commit -m "perf: add agent channel replay benchmark"
```

### Task 2: Refactor JSON-RPC Parsing and Request Lifetime

**Files:**
- Modify: `swift-app/Sources/Core/Agent/JSONRPCChannel.swift:1-190`
- Modify: `swift-app/tools/agenttest.swift:54-90`

**Interfaces:**
- Consumes: existing JSON-RPC callbacks and `NdjsonSplitter.feed(_:)`.
- Produces: `JSONRPCChannel.init(callbackQueue:parser:)`, `failPending(reason:)`, and `debugPendingCount`.

- [ ] **Step 1: Add failing tests for callback affinity, wire order, and teardown**

Add this helper inside `AgentTest.main()` near `check`:

```swift
func wait(_ semaphore: DispatchSemaphore, seconds: Double = 1) -> Bool {
    semaphore.wait(timeout: .now() + seconds) == .success
}
```

Add a new JSON-RPC test section after the existing routing tests:

```swift
print("— JSONRPCChannel callback queue + lifecycle —")
let deliveryQueue = DispatchQueue(label: "goty.agenttest.rpc-callback")
let deliveryKey = DispatchSpecificKey<String>()
deliveryQueue.setSpecific(key: deliveryKey, value: "rpc")
let delivered = DispatchSemaphore(value: 0)
let queued = JSONRPCChannel(callbackQueue: deliveryQueue)
var callbackOrder: [String] = []
var callbackQueueWasCorrect = true
queued.onNotification = { method, _ in
    callbackQueueWasCorrect = callbackQueueWasCorrect
        && DispatchQueue.getSpecific(key: deliveryKey) == "rpc"
    callbackOrder.append(method)
    if callbackOrder.count == 2 { delivered.signal() }
}
DispatchQueue.global(qos: .userInitiated).async {
    queued.feed(Array("{\"method\":\"first\"}\n{\"method\":\"second\"}\n".utf8))
}
check(wait(delivered), "JSON-RPC queued callbacks finish")
check(callbackQueueWasCorrect, "JSON-RPC callbacks use configured queue")
check(callbackOrder == ["first", "second"], "JSON-RPC callbacks keep wire order")

let teardown = JSONRPCChannel()
teardown.onOutbound = { _ in }
var teardownFailures = 0
teardown.request("one", [:]) { result in
    if case .failure = result { teardownFailures += 1 }
}
teardown.request("two", [:]) { result in
    if case .failure = result { teardownFailures += 1 }
}
check(teardown.debugPendingCount == 2, "JSON-RPC tracks pending requests")
teardown.failPending(reason: "transport disconnected")
teardown.failPending(reason: "duplicate teardown")
check(teardownFailures == 2, "JSON-RPC teardown fails each request once")
check(teardown.debugPendingCount == 0, "JSON-RPC teardown drains pending requests")
```

- [ ] **Step 2: Run the Swift tests and verify the new API fails to compile**

Run: `swift-app/run-tests.sh`

Expected: FAIL because `JSONRPCChannel` has no `callbackQueue` initializer, `failPending`, or `debugPendingCount`.

- [ ] **Step 3: Add a controlled parser test that exposes lock contention**

Add a `parser` closure parameter to the test construction and a test that blocks parsing while registering a request:

```swift
let parserEntered = DispatchSemaphore(value: 0)
let parserRelease = DispatchSemaphore(value: 0)
let requestReturned = DispatchSemaphore(value: 0)
let contention = JSONRPCChannel(parser: { data in
    parserEntered.signal()
    _ = parserRelease.wait(timeout: .now() + 2)
    return try? JSONSerialization.jsonObject(with: data)
})
contention.onOutbound = { _ in }
DispatchQueue.global(qos: .userInitiated).async {
    contention.feed(Array("{\"method\":\"blocked-parser\"}\n".utf8))
}
check(wait(parserEntered), "JSON-RPC parser seam entered")
DispatchQueue.global(qos: .userInitiated).async {
    contention.request("must-not-wait-for-parser", [:]) { _ in }
    requestReturned.signal()
}
check(wait(requestReturned, seconds: 0.25),
      "request registration does not wait for JSON parsing")
parserRelease.signal()
contention.failPending(reason: "test complete")
```

- [ ] **Step 4: Implement narrow locks and ordered callback batching**

Replace the single lock with framing and state locks, inject the parser, and represent delivery in wire order:

```swift
final class JSONRPCChannel {
    typealias Parser = (Data) -> Any?

    private enum Delivery {
        case unparseable(String)
        case notification(String, [String: Any])
        case request(Int, String, [String: Any])
        case replayRequest(Int, String, [String: Any])
        case orphan([String: Any])
        case completion(Result<[String: Any], RPCFailure>,
                        (Result<[String: Any], RPCFailure>) -> Void)
    }

    private let callbackQueue: DispatchQueue?
    private let parser: Parser
    private let framingLock = NSLock()
    private let stateLock = NSLock()
    private var splitter = NdjsonSplitter()
    private var _messagesRouted = 0
    private var _unparseableLines = 0

    init(callbackQueue: DispatchQueue? = nil,
         parser: @escaping Parser = { try? JSONSerialization.jsonObject(with: $0) }) {
        self.callbackQueue = callbackQueue
        self.parser = parser
    }

    var messagesRouted: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _messagesRouted
    }

    var unparseableLines: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _unparseableLines
    }

    var debugPendingCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pending.count
    }
}
```

In `feed`, hold `framingLock` only while calling `splitter.feed(bytes)`, parse each returned line with `parser` after unlocking, and hold `stateLock` only for echo checks, counters, and `pending.removeValue(forKey:)`. Append one `Delivery` value at the point each wire message is recognized. Do not group callbacks by type.

Deliver the finished array with one queue hop:

```swift
private func deliver(_ deliveries: [Delivery]) {
    guard !deliveries.isEmpty else { return }
    let work = { [self] in
        for delivery in deliveries {
            switch delivery {
            case .unparseable(let line): onUnparseable?(line)
            case .notification(let method, let params): onNotification?(method, params)
            case .request(let id, let method, let params): onRequest?(id, method, params)
            case .replayRequest(let id, let method, let params): onReplayRequest?(id, method, params)
            case .orphan(let result): onOrphanResult?(result)
            case .completion(let result, let completion): completion(result)
            }
        }
    }
    if let callbackQueue {
        callbackQueue.async(execute: work)
    } else {
        work()
    }
}
```

Update `request` and `send` to use `stateLock`, not `framingLock`.

- [ ] **Step 5: Implement pending-request failure outside the lock**

```swift
func failPending(reason: String) {
    stateLock.lock()
    let completions = Array(pending.values)
    pending.removeAll(keepingCapacity: true)
    stateLock.unlock()
    let failure = Result<[String: Any], RPCFailure>.failure(.message(reason))
    deliver(completions.map { .completion(failure, $0) })
}
```

- [ ] **Step 6: Run tests and the benchmark**

Run: `swift-app/run-tests.sh`

Expected: all tests pass, including callback affinity, order, contention, and teardown.

Run: `swift-app/run-agent-bench.sh`

Expected: exit 0 with the same byte/message counts as Task 1. Preserve the throughput result for final comparison.

- [ ] **Step 7: Commit the JSON-RPC refactor**

```bash
git add swift-app/Sources/Core/Agent/JSONRPCChannel.swift swift-app/tools/agenttest.swift
git commit -m "refactor(agent): isolate JSON-RPC parsing and callbacks"
```

### Task 3: Give LineChannel the Same Execution Contract

**Files:**
- Modify: `swift-app/Sources/Core/Agent/LineChannel.swift:1-70`
- Modify: `swift-app/tools/agenttest.swift`

**Interfaces:**
- Consumes: the callback queue and narrow-lock pattern established by `JSONRPCChannel`.
- Produces: `LineChannel.init(callbackQueue:parser:)`; `onFrame` continues to receive `([String: Any], Bool)` with its replay value preserved.

- [ ] **Step 1: Add a failing replay and queue-affinity test**

```swift
print("— LineChannel callback queue + replay metadata —")
let lineQueue = DispatchQueue(label: "goty.agenttest.line-callback")
let lineKey = DispatchSpecificKey<String>()
lineQueue.setSpecific(key: lineKey, value: "line")
let lineDone = DispatchSemaphore(value: 0)
let lineChannel = LineChannel(callbackQueue: lineQueue)
var lineQueueWasCorrect = false
var replayFlag = false
lineChannel.onFrame = { _, replay in
    lineQueueWasCorrect = DispatchQueue.getSpecific(key: lineKey) == "line"
    replayFlag = replay
    lineDone.signal()
}
DispatchQueue.global(qos: .userInitiated).async {
    lineChannel.feed(Array("{\"type\":\"message\"}\n".utf8), replay: true)
}
check(wait(lineDone), "line callback finishes")
check(lineQueueWasCorrect, "line callback uses configured queue")
check(replayFlag, "line callback preserves replay metadata")

let replayBoundaryDone = DispatchSemaphore(value: 0)
let replayBoundary = LineChannel(callbackQueue: lineQueue)
var replaySequence: [Bool] = []
replayBoundary.onFrame = { _, replay in
    replaySequence.append(replay)
    if replaySequence.count == 2 { replayBoundaryDone.signal() }
}
replayBoundary.feed(Array("{\"type\":\"snapshot\"}\n".utf8), replay: true)
replayBoundary.feed(Array("{\"type\":\"live\"}\n".utf8), replay: false)
check(wait(replayBoundaryDone), "line replay/live callbacks finish")
check(replaySequence == [true, false], "line callbacks preserve replay/live order")
```

- [ ] **Step 2: Run tests to verify the initializer is missing**

Run: `swift-app/run-tests.sh`

Expected: FAIL because `LineChannel` has no `callbackQueue` initializer.

- [ ] **Step 3: Refactor framing, state, parsing, and delivery**

Use the same constructor shape as JSON-RPC:

```swift
typealias Parser = (Data) -> Any?
private let callbackQueue: DispatchQueue?
private let parser: Parser
private let framingLock = NSLock()
private let stateLock = NSLock()

init(callbackQueue: DispatchQueue? = nil,
     parser: @escaping Parser = { try? JSONSerialization.jsonObject(with: $0) }) {
    self.callbackQueue = callbackQueue
    self.parser = parser
}
```

Extract complete lines under `framingLock`, parse outside both locks, and update the echo ring/counters under `stateLock`. Build `[(frame: [String: Any], replay: Bool)]`, then deliver the whole array with one callback-queue closure. Collect unparseable lines and deliver `onUnparseable` after unlocking; never call it under `stateLock`.

- [ ] **Step 4: Run all Swift tests**

Run: `swift-app/run-tests.sh`

Expected: all tests pass.

- [ ] **Step 5: Commit the LineChannel refactor**

```bash
git add swift-app/Sources/Core/Agent/LineChannel.swift swift-app/tools/agenttest.swift
git commit -m "refactor(agent): queue parsed line callbacks"
```

### Task 4: Add Shared Connection Execution Primitives

**Files:**
- Create: `swift-app/Sources/Core/Agent/AgentSessionExecution.swift`
- Modify: `swift-app/tools/agenttest.swift`

**Interfaces:**
- Produces: `AgentSessionExecution.runOffMain(work:completion:)` and `AgentConnectionGate.open(work:onStale:completion:)`, `invalidate()`.
- Consumed by: Tasks 6-8 adapter connection migrations.

- [ ] **Step 1: Add failing generation and execution tests**

```swift
print("— agent session execution boundary —")
let workStarted = DispatchSemaphore(value: 0)
let releaseWork = DispatchSemaphore(value: 0)
var workWasOffMain = false
var completionWasMain = false
var executionDone = false
AgentSessionExecution.runOffMain(work: {
    workWasOffMain = !Thread.isMainThread
    workStarted.signal()
    _ = releaseWork.wait(timeout: .now() + 2)
    return 42
}, completion: { value in
    completionWasMain = Thread.isMainThread && value == 42
    executionDone = true
})
check(wait(workStarted), "connection work starts")
var markerRan = false
DispatchQueue.main.async { markerRan = true }
let markerDeadline = Date().addingTimeInterval(0.5)
while !markerRan, Date() < markerDeadline {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
}
check(markerRan, "blocked connection work does not block main queue")
releaseWork.signal()
let completionDeadline = Date().addingTimeInterval(1)
while !executionDone, Date() < completionDeadline {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
}
check(workWasOffMain, "connection work runs off main")
check(completionWasMain, "connection completion returns to main")

let staleStarted = DispatchSemaphore(value: 0)
let staleRelease = DispatchSemaphore(value: 0)
let gate = AgentConnectionGate()
var acceptedConnections: [String] = []
var discardedConnections: [String] = []
gate.open(work: {
    staleStarted.signal()
    _ = staleRelease.wait(timeout: .now() + 2)
    return "old"
}, onStale: { discardedConnections.append($0) },
   completion: { acceptedConnections.append($0) })
check(wait(staleStarted), "old connection attempt starts")
gate.open(work: { "new" },
          onStale: { discardedConnections.append($0) },
          completion: { acceptedConnections.append($0) })
let acceptedDeadline = Date().addingTimeInterval(1)
while acceptedConnections.isEmpty, Date() < acceptedDeadline {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
}
staleRelease.signal()
let discardedDeadline = Date().addingTimeInterval(1)
while discardedConnections.isEmpty, Date() < discardedDeadline {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
}
check(acceptedConnections == ["new"], "only newest connection is accepted")
check(discardedConnections == ["old"], "stale connection is discarded")
```

- [ ] **Step 2: Run tests and verify the types are missing**

Run: `swift-app/run-tests.sh`

Expected: FAIL with unknown `AgentConnectionGate` and `AgentSessionExecution`.

- [ ] **Step 3: Implement the focused execution helper**

Create `AgentSessionExecution.swift`:

```swift
import Foundation

enum AgentSessionExecution {
    static func runOffMain<Value>(
        work: @escaping () -> Value,
        completion: @escaping (Value) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let value = work()
            DispatchQueue.main.async {
                completion(value)
            }
        }
    }
}

@MainActor
final class AgentConnectionGate {
    private var generation: UInt64 = 0

    func open<Value>(
        work: @escaping () -> Value,
        onStale: @escaping (Value) -> Void,
        completion: @escaping (Value) -> Void
    ) {
        generation &+= 1
        let candidate = generation
        AgentSessionExecution.runOffMain(work: work) { [weak self] value in
            guard let self, self.generation == candidate else {
                onStale(value)
                return
            }
            completion(value)
        }
    }

    func invalidate() {
        generation &+= 1
    }
}
```

Do not add a serial global connection queue; separate panes must be able to connect concurrently.

- [ ] **Step 4: Run all Swift tests**

Run: `swift-app/run-tests.sh`

Expected: all tests pass and the delayed work test proves the main queue remains responsive.

- [ ] **Step 5: Commit the execution primitives**

```bash
git add swift-app/Sources/Core/Agent/AgentSessionExecution.swift swift-app/tools/agenttest.swift
git commit -m "refactor(agent): add connection execution boundary"
```

### Task 5: Enforce the Main-Actor Adapter Contract

**Files:**
- Modify: `swift-app/Sources/Core/Agent/AgentSessioning.swift:30-205`
- Modify: `swift-app/Sources/Core/Agent/AgentRegistry.swift:25-95`
- Modify: `swift-app/Sources/Core/Agent/Adapters/CodexSession.swift:11-72`
- Modify: `swift-app/Sources/Core/Agent/Adapters/PiSession.swift:19-155,898-1010`
- Modify: `swift-app/Sources/Core/Agent/Adapters/ClaudeSession.swift:14-65`
- Modify: `swift-app/Sources/Core/Agent/Adapters/OmpSession.swift:852-864`
- Modify: `swift-app/Sources/UI/Agent/AgentPaneHost.swift:212-220,997-1205`
- Modify: `swift-app/Sources/App/AppDelegate.swift:640-665`
- Modify: `swift-app/tools/agenttest.swift`
- Modify: `swift-app/tools/agentprobe.swift`, `swift-app/tools/compactprobe.swift`, `swift-app/tools/replayprobe.swift`

**Interfaces:**
- Consumes: channel callback queues from Tasks 2-3.
- Produces: main-actor `AgentSessioning`, main-actor `AgentSessionDelegate`, and main-actor adapter factories.

- [ ] **Step 1: Add a failing production-affinity test**

Configure a `LineChannel(callbackQueue: .main)` and feed it from a background queue. Use the existing main-run-loop loop from Task 4 and assert `Thread.isMainThread` inside `onFrame`. Repeat for `JSONRPCChannel(callbackQueue: .main)` inside `onNotification`.

```swift
let mainLineDone = DispatchSemaphore(value: 0)
let mainLine = LineChannel(callbackQueue: .main)
var mainLineWasMain = false
mainLine.onFrame = { _, _ in
    mainLineWasMain = Thread.isMainThread
    mainLineDone.signal()
}
DispatchQueue.global().async {
    mainLine.feed(Array("{\"type\":\"main-check\"}\n".utf8))
}
let mainLineDeadline = Date().addingTimeInterval(1)
while mainLineDone.wait(timeout: .now()) != .success,
      Date() < mainLineDeadline {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
}
check(mainLineWasMain, "production line callbacks reach main thread")

let mainRPCDone = DispatchSemaphore(value: 0)
let mainRPC = JSONRPCChannel(callbackQueue: .main)
var mainRPCWasMain = false
mainRPC.onNotification = { _, _ in
    mainRPCWasMain = Thread.isMainThread
    mainRPCDone.signal()
}
DispatchQueue.global().async {
    mainRPC.feed(Array("{\"method\":\"main-check\"}\n".utf8))
}
let mainRPCDeadline = Date().addingTimeInterval(1)
while mainRPCDone.wait(timeout: .now()) != .success,
      Date() < mainRPCDeadline {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
}
check(mainRPCWasMain, "production JSON-RPC callbacks reach main thread")
```

- [ ] **Step 2: Annotate the protocol boundary and factories**

In `AgentSessioning.swift`:

```swift
@MainActor
protocol AgentSessioning: AnyObject {

@MainActor
protocol AgentSessionDelegate: AnyObject {
```

In `AgentRegistry.swift`:

```swift
struct AgentDescriptor {
    let make: @MainActor (AgentPaneParams) -> any AgentSessioning
}
```

Annotate the AppDelegate method containing `descriptor.make(...)` with `@MainActor`. Mark standalone probe entry points/delegates and `OmpCommandProbeSink` `@MainActor` where they construct or consume sessions.

- [ ] **Step 3: Configure production channels for main delivery**

Use these property initializers:

```swift
// CodexSession
private let client = JSONRPCChannel(callbackQueue: .main)

// PiSession and ClaudeSession
private let channel = LineChannel(callbackQueue: .main)
```

Change Pi's callback to derive replay state from the delivered flag:

```swift
channel.onFrame = { [weak self] frame, replay in
    guard let self else { return }
    self.mapper.replaying = replay
    self.suppressReplay = replay && self.suppressesRingReplay
    defer {
        self.mapper.replaying = false
        self.suppressReplay = false
    }
    self.handleFrame(frame)
}
```

Remove the `mapper.replaying` and `suppressReplay` mutations wrapped around `channel.feed` in `handleTransportFrame`; pass only `replay: true` or `false` into the channel.

- [ ] **Step 4: Remove redundant delegate-side dispatches**

Because the delegate protocol is main-actor isolated, make `AgentPaneHost.session(_:didEmit:)`, `sessionDidFail`, and `session(_:didDisconnectBecause:)` execute their existing bodies directly. Do not change event semantics or reorder event handling.

- [ ] **Step 5: Typecheck and repair only explicit actor-boundary errors**

Run: `swift-app/run-tests.sh`

Expected initially: compiler errors at background transport closures that call actor-isolated adapter methods. For each output/snapshot closure, capture the channel in a main-actor method before constructing the closure and call `channel.feed` from the reader thread; for control frames and disconnects use `DispatchQueue.main.async` before accessing `self`. Do not move raw JSON parsing to main.

Run again: `swift-app/run-tests.sh`

Expected: all tests pass with no goty-owned actor isolation warnings.

- [ ] **Step 6: Commit the execution-domain contract**

```bash
git add swift-app/Sources/Core/Agent/AgentSessioning.swift \
  swift-app/Sources/Core/Agent/AgentRegistry.swift \
  swift-app/Sources/Core/Agent/Adapters/CodexSession.swift \
  swift-app/Sources/Core/Agent/Adapters/PiSession.swift \
  swift-app/Sources/Core/Agent/Adapters/ClaudeSession.swift \
  swift-app/Sources/Core/Agent/Adapters/OmpSession.swift \
  swift-app/Sources/UI/Agent/AgentPaneHost.swift \
  swift-app/Sources/App/AppDelegate.swift \
  swift-app/tools/agenttest.swift swift-app/tools/agentprobe.swift \
  swift-app/tools/compactprobe.swift swift-app/tools/replayprobe.swift
git commit -m "refactor(agent): confine session state to main actor"
```

### Task 6: Move Codex Connection I/O Off Main and Close RPC Epochs

**Files:**
- Modify: `swift-app/Sources/Core/Agent/Adapters/CodexSession.swift:363-516,1200-1260`
- Modify: `swift-app/tools/agenttest.swift`

**Interfaces:**
- Consumes: `AgentConnectionGate.open`, `AgentConnectionGate.invalidate`, and `JSONRPCChannel.failPending`.
- Produces: generation-fenced asynchronous Codex attach/spawn with deterministic pending-request teardown.

- [ ] **Step 1: Re-run the connection-gate contract before adapter wiring**

Run: `swift-app/run-tests.sh`

Expected: PASS for `only newest connection is accepted` and `stale connection is discarded`. These assertions test the same gate Codex will own, rather than a separate model of its behavior.

- [ ] **Step 2: Replace synchronous `openTransport` with asynchronous opening**

Add state:

```swift
private let connectionGate = AgentConnectionGate()

private enum TransportOpenIntent {
    case initial
    case reconnect
}
```

Change `openTransport` to capture only immutable connection inputs and the channel for reader-thread parsing, then deliver the result on main:

```swift
private func openTransport(
    completion: @escaping (SessionDaemon.OpenPaneResult?) -> Void
) {
    let daemon = self.daemon
    let paneId = self.paneId
    let cwd = self.cwd
    let environment = self.environment
    let grid = self.grid
    let client = self.client
    connectionGate.open(work: {
        daemon.openPaneWithAttachment(
            id: paneId, cwd: cwd, shell: "codex", args: ["app-server"],
            environment: environment, grid: grid,
            noEcho: true, ringBytes: 16_777_216,
            onFrame: { [weak self] kind, data in
                switch kind {
                case SessionOutputKind.output:
                    client.feed([UInt8](data))
                case SessionOutputKind.snapshot:
                    client.feed([UInt8](data), replay: true)
                default:
                    DispatchQueue.main.async {
                        self?.handleControlFrame(kind: kind, data: data)
                    }
                }
            },
            onDisconnect: { [weak self] in
                DispatchQueue.main.async { self?.transportDisconnected() }
            })
    }, onStale: { opened in
        opened?.session.close()
    }, completion: completion)
}
```

Split the old frame handler so `handleControlFrame` never parses output/snapshot. Move the existing attach/adopt versus handshake branches into the `openTransport` completion. Call `opened.session.start()` only after assigning `pane` on main.

- [ ] **Step 3: Fence connect, reconnect, exit, disconnect, and shutdown**

At the start of each connect/reconnect attempt:

```swift
client.failPending(reason: "transport epoch replaced")
openTransport { [weak self] opened in
    self?.finishOpeningTransport(opened, intent: .initial,
                                 completion: completion)
}
```

Use `intent: .reconnect` in `reconnect`.

Add this main-actor helper by extracting the current post-`openTransport`
branches from `connect`/`reconnect`:

```swift
private func finishOpeningTransport(
    _ opened: SessionDaemon.OpenPaneResult?,
    intent: TransportOpenIntent,
    completion: ((Bool) -> Void)?
) {
    guard let opened else {
        connected = false
        delegate?.sessionDidFail(self, reason: "sessiond 不可用")
        completion?(false)
        return
    }
    pane = opened.session
    opened.session.start()
    if opened.attachedExisting {
        switch intent {
        case .initial:
            finishInitialAttachment(completion: completion)
        case .reconnect:
            emit([.ready])
            completion?(true)
        }
    } else {
        handshake(completion)
    }
}
```

Define
`private func finishInitialAttachment(completion: ((Bool) -> Void)?)` by
moving the entire existing `if opened.attachedExisting` body from `connect`
into it, including model catalog loading, restored-thread ownership recovery,
transcript rebuild, `.ready`, and completion. The `.reconnect` branch above
deliberately preserves reconnect's current lightweight attached-pane behavior.

On disconnect, emit the existing reconnect signal and then fail pending work. On process exit and shutdown:

```swift
connectionGate.invalidate()
client.failPending(reason: "codex transport closed")
pane?.close()
pane = nil
connected = false
```

Keep the existing user-facing Chinese error/notice strings and ownership-denied behavior.

- [ ] **Step 4: Run Codex and full Swift contracts**

Run: `swift-app/run-tests.sh`

Expected: all tests pass, including Codex attach replay, permissions, cancellation, history paging, and the new generation/teardown tests.

- [ ] **Step 5: Commit the Codex migration**

```bash
git add swift-app/Sources/Core/Agent/Adapters/CodexSession.swift swift-app/tools/agenttest.swift
git commit -m "fix(agent): serialize Codex transport lifecycle"
```

### Task 7: Move Pi/OMP Connection I/O Off Main Without Breaking Replay

**Files:**
- Modify: `swift-app/Sources/Core/Agent/Adapters/PiSession.swift:249-330,580-610,898-1010`
- Modify: `swift-app/Sources/Core/Agent/Adapters/OmpSession.swift`
- Modify: `swift-app/tools/agenttest.swift`

**Interfaces:**
- Consumes: main-queued `LineChannel`, replay flag delivery, and shared connection execution primitives.
- Produces: generation-fenced Pi/OMP connection installation and callback-time replay suppression.

- [ ] **Step 1: Add a failing replay-state regression test**

Extract the replay decision as a pure PiSession helper:

```swift
static func replayState(replay: Bool, suppressesRingReplay: Bool)
    -> (mapperReplaying: Bool, suppressContent: Bool) {
    (replay, replay && suppressesRingReplay)
}
```

Add tests before implementing it:

```swift
let ompReplay = PiSession.replayState(replay: true, suppressesRingReplay: true)
check(ompReplay.mapperReplaying && ompReplay.suppressContent,
      "OMP replay maps history but suppresses content")
let piReplay = PiSession.replayState(replay: true, suppressesRingReplay: false)
check(piReplay.mapperReplaying && !piReplay.suppressContent,
      "Pi replay maps history without OMP suppression")
let liveFrame = PiSession.replayState(replay: false, suppressesRingReplay: true)
check(!liveFrame.mapperReplaying && !liveFrame.suppressContent,
      "live OMP frame is never replay-suppressed")
```

Run: `swift-app/run-tests.sh`

Expected: FAIL because `replayState` does not exist.

- [ ] **Step 2: Implement replay state and keep callback-time scoping**

Implement the helper exactly as above and use it inside `channel.onFrame`. Set mapper/suppression state immediately before `handleFrame`, then reset both in `defer`. Do not set either flag around asynchronous `channel.feed`.

- [ ] **Step 3: Return pane installation and handshake to main**

Add `private let connectionGate = AgentConnectionGate()`. Replace the current background block in `openPane` with `connectionGate.open`: the `work` closure only calls `daemon.openPaneWithAttachment`; `onStale` closes a non-nil returned session; the `completion` closure assigns `pane`, `connected`, and `attachedExistingPane`, starts the pane, and invokes `beginHandshakeAfterSpawn` on main.

Build `args` and capture every immutable opener input on main before starting
the gate. Capture `channel` for output parsing; only control/disconnect paths
may capture `self`, and those paths must hop to main:

```swift
var args = ["--mode", Self.spawnMode]
appendSpawnArgs(&args, resume: sessionId)
let daemon = self.daemon
let paneId = self.paneId
let cwd = self.cwd
let shellName = self.shellName
let environment = self.environment
let grid = self.grid
let channel = self.channel
connectionGate.open(work: {
    daemon.openPaneWithAttachment(
        id: paneId, cwd: cwd, shell: shellName, args: args,
        environment: environment, grid: grid,
        noEcho: true, ringBytes: 1_048_576,
        onFrame: { [weak self] kind, data in
            switch kind {
            case SessionOutputKind.output:
                channel.feed([UInt8](data), replay: false)
            case SessionOutputKind.snapshot:
                channel.feed([UInt8](data), replay: true)
            default:
                DispatchQueue.main.async {
                    self?.handleControlFrame(kind: kind, data: data)
                }
            }
        },
        onDisconnect: { [weak self] in
            DispatchQueue.main.async { self?.transportDisconnected() }
        })
}, onStale: { opened in
    opened?.session.close()
}, completion: { [weak self] opened in
    guard let self else { opened?.session.close(); return }
    self.finishOpeningPane(opened, completion: completion)
})
```

Define the extracted main-actor completion explicitly:

```swift
private func finishOpeningPane(
    _ opened: SessionDaemon.OpenPaneResult?,
    completion: ((Bool) -> Void)?
) {
    guard let opened else {
        connected = false
        delegate?.sessionDidFail(self, reason: "sessiond 不可用")
        completion?(false)
        return
    }
    pane = opened.session
    attachedExistingPane = opened.attachedExisting
    opened.session.start()
    beginHandshakeAfterSpawn(attachedExisting: opened.attachedExisting,
                             completion: completion)
}
```

Extract the existing exited-frame body into
`handleControlFrame(kind:data:)`, and the existing disconnect body into
`transportDisconnected()`. Starting another `open` advances the gate
automatically. Call `connectionGate.invalidate()` before closing the pane in
process exit and shutdown. Preserve the 1 MiB ring, `rpc-ui` OMP mode,
store-authoritative replay gate, and existing ready-frame handshake behavior.

- [ ] **Step 4: Run the full Swift suite**

Run: `swift-app/run-tests.sh`

Expected: all tests pass, especially OMP store replay, chunk assembly, missed-settle healing, extension UI, and Pi history tests.

- [ ] **Step 5: Commit the Pi/OMP migration**

```bash
git add swift-app/Sources/Core/Agent/Adapters/PiSession.swift \
  swift-app/Sources/Core/Agent/Adapters/OmpSession.swift \
  swift-app/tools/agenttest.swift
git commit -m "fix(agent): serialize Pi and OMP transport lifecycle"
```

### Task 8: Move Claude Connection I/O Off Main

**Files:**
- Modify: `swift-app/Sources/Core/Agent/Adapters/ClaudeSession.swift:170-220,480-515`
- Modify: `swift-app/tools/agenttest.swift`

**Interfaces:**
- Consumes: main-queued `LineChannel` and shared connection execution primitives.
- Produces: generation-fenced Claude attach/spawn and main-actor process state.

- [ ] **Step 1: Add the Claude generation regression case**

Extend the Task 4 gate test with a shutdown case:

```swift
let shutdownStarted = DispatchSemaphore(value: 0)
let shutdownRelease = DispatchSemaphore(value: 0)
var shutdownDiscarded = false
gate.open(work: {
    shutdownStarted.signal()
    _ = shutdownRelease.wait(timeout: .now() + 2)
    return "shutdown"
}, onStale: { _ in shutdownDiscarded = true }, completion: { _ in })
check(wait(shutdownStarted), "shutdown candidate starts")
gate.invalidate()
shutdownRelease.signal()
let shutdownDeadline = Date().addingTimeInterval(1)
while !shutdownDiscarded, Date() < shutdownDeadline {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
}
check(shutdownDiscarded, "shutdown rejects delayed open result")
```

- [ ] **Step 2: Make `openPane` asynchronous and generation-fenced**

Add `private let connectionGate = AgentConnectionGate()`, capture the Claude shell/args and channel on main, and run only `openPaneWithAttachment` inside `connectionGate.open`. `onStale` closes a returned session. In the main completion:

```swift
guard let self else { opened?.session.close(); return }
guard let opened else {
    self.connected = false
    self.delegate?.sessionDidFail(self, reason: "sessiond 不可用")
    completion?(false)
    return
}
self.pane = opened.session
self.processAlive = true
opened.session.start()
```

Immediately after `opened.session.start()`, retain the current attach/resume decision: attached panes emit ready and complete successfully; fresh panes follow the existing first-turn initialization path. Output/snapshot frames feed `LineChannel` on the reader thread; exit and disconnect state changes hop to main. Starting another `open` advances the gate automatically; call `connectionGate.invalidate()` on shutdown.

- [ ] **Step 3: Run all Swift tests**

Run: `swift-app/run-tests.sh`

Expected: all tests pass, especially Claude stream deduplication, permissions, history replay, runtime-mode switching, and reconnect behavior.

- [ ] **Step 4: Commit the Claude migration**

```bash
git add swift-app/Sources/Core/Agent/Adapters/ClaudeSession.swift swift-app/tools/agenttest.swift
git commit -m "fix(agent): serialize Claude transport lifecycle"
```

### Task 9: Repair Test Watchdog and Temporary-Directory Cleanup

**Files:**
- Create: `swift-app/tools/run-guarded.sh`
- Modify: `swift-app/run-tests.sh:1-30,148-182`
- Modify: `swift-app/Sources/Core/Agent/Adapters/CodexSession.swift:550`

**Interfaces:**
- Produces: `run-guarded.sh <timeout-seconds> <command> [args...]`, preserving the child exit status and always stopping its watchdog.
- Consumed by: all four headless test-binary invocations in `run-tests.sh`.

- [ ] **Step 1: Add the watchdog wrapper**

Create `swift-app/tools/run-guarded.sh`:

```bash
#!/bin/bash
set -u

timeout_seconds=$1
shift
child_pid=""
watchdog_pid=""

cleanup() {
    local status=$?
    trap - EXIT HUP INT TERM
    if [ -n "$watchdog_pid" ]; then
        kill "$watchdog_pid" 2>/dev/null || true
        wait "$watchdog_pid" 2>/dev/null || true
    fi
    if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
        kill "$child_pid" 2>/dev/null || true
        wait "$child_pid" 2>/dev/null || true
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

"$@" &
child_pid=$!
( sleep "$timeout_seconds" && kill -9 "$child_pid" 2>/dev/null ) >/dev/null 2>&1 &
watchdog_pid=$!

if wait "$child_pid"; then
    child_status=0
else
    child_status=$?
fi
exit "$child_status"
```

Run: `chmod +x swift-app/tools/run-guarded.sh`

- [ ] **Step 2: Prove the original failure path now preserves status**

Run: `swift-app/tools/run-guarded.sh 1 /bin/sh -c 'exit 23'`

Expected: exit status 23, returned immediately rather than after one second.

Run a signal cleanup probe, send `TERM` to the wrapper, and verify every direct
child (test process and watchdog) is gone:

```bash
swift-app/tools/run-guarded.sh 30 /bin/sleep 30 &
wrapper_pid=$!
guard_children=""
for _ in $(seq 1 100); do
    guard_children=$(pgrep -P "$wrapper_pid" || true)
    [ "$(printf '%s\n' "$guard_children" | sed '/^$/d' | wc -l)" -ge 2 ] && break
    sleep 0.01
done
test "$(printf '%s\n' "$guard_children" | sed '/^$/d' | wc -l)" -ge 2
kill -TERM "$wrapper_pid"
if wait "$wrapper_pid"; then wrapper_status=0; else wrapper_status=$?; fi
test "$wrapper_status" -eq 143
for child in $guard_children; do ! kill -0 "$child" 2>/dev/null; done
```

Expected: the wrapper exits 143 and its child and watchdog are both gone.

- [ ] **Step 3: Add exact per-run cleanup to `run-tests.sh`**

Immediately after creating `B`, add:

```bash
cleanup_build_dir() {
    local status=$?
    trap - EXIT HUP INT TERM
    case "$B" in
        /tmp/goty-build-[0-9]*) rm -rf -- "$B" ;;
    esac
    exit "$status"
}
trap cleanup_build_dir EXIT
```

Delete the inline `run_guarded` function and replace each invocation with:

```bash
tools/run-guarded.sh 300 "$B"/goty-layouttest-test
tools/run-guarded.sh 300 "$B"/goty-filestest-test
tools/run-guarded.sh 300 "$B"/goty-aitest-test
tools/run-guarded.sh 300 "$B"/goty-agenttest-test
```

- [ ] **Step 4: Remove the goty-owned Swift warning**

In `CodexSession.startThread`, replace:

```swift
var readyEvents: [AgentSessionEvent] = [.configChanged(self.configOptions), .ready]
```

with:

```swift
let readyEvents: [AgentSessionEvent] = [.configChanged(self.configOptions), .ready]
```

- [ ] **Step 5: Run the full test suite and verify no new directory remains**

Record the count first:

Run: `find /private/tmp -maxdepth 1 -type d -name 'goty-build-*' -print | wc -l`

Run: `swift-app/run-tests.sh`

Run the same count command again.

Expected: all tests pass and the before/after counts are equal. Do not delete the historical directories.

- [ ] **Step 6: Commit the runner repair**

```bash
git add swift-app/tools/run-guarded.sh swift-app/run-tests.sh \
  swift-app/Sources/Core/Agent/Adapters/CodexSession.swift
git commit -m "fix(test): clean watchdogs and temporary builds"
```

### Task 10: Full Verification and Performance Audit

**Files:**
- Verify only; modify implementation files only if a check identifies a regression caused by Tasks 1-9.

**Interfaces:**
- Consumes: every deliverable above.
- Produces: build/test/performance evidence suitable for the final report.

- [ ] **Step 1: Re-run the release-mode replay benchmark**

Run: `swift-app/run-agent-bench.sh`

Expected: identical byte/message counts to Task 1. Compare `mib_per_second` with the saved baseline; report the percentage change without claiming significance when the difference is within run-to-run noise.

- [ ] **Step 2: Run Rust formatting**

Run: `cargo fmt --manifest-path swift-app/sessiond/Cargo.toml -- --check`

Expected: exit 0 with no output.

- [ ] **Step 3: Run Rust Clippy**

Run: `cargo clippy --manifest-path swift-app/sessiond/Cargo.toml --all-targets -- -D warnings`

Expected: exit 0 with no warnings.

- [ ] **Step 4: Run Rust tests**

Run: `cargo test --manifest-path swift-app/sessiond/Cargo.toml`

Expected: 23 or more tests pass, with zero failures.

- [ ] **Step 5: Run every enabled Swift headless test**

Run: `swift-app/run-tests.sh`

Expected: `ALL PASS` for layout, files, AI, and `agenttest: all passed`; no goty-owned Swift warnings.

- [ ] **Step 6: Build and package the macOS app**

Invoke the `macos-build` skill, then run: `swift-app/build.sh`

Expected: exit 0, `swift-app/Goty.app` and bundled `goty-sessiond` produced, with no new goty-owned Swift warnings.

- [ ] **Step 7: Audit actor and blocking-I/O invariants**

Run:

```bash
rg -n 'openPaneWithAttachment\(' swift-app/Sources/Core/Agent/Adapters
rg -n 'JSONRPCChannel\(|LineChannel\(' swift-app/Sources/Core/Agent/Adapters
rg -n 'handleTransportFrame|handleControlFrame' swift-app/Sources/Core/Agent/Adapters
```

Expected: every adapter open is inside the `work` closure passed to
`AgentConnectionGate.open` (which delegates to
`AgentSessionExecution.runOffMain`); production channels specify `.main`;
output/snapshot parsing remains on the reader path while control-state handling
crosses to main.

- [ ] **Step 8: Confirm only intended work is committed**

Run: `git status --short`

Expected: only the user's pre-existing `README.md` modification and `swift-app/agent-web/tools/` untracked directory remain. Do not stage or modify either.

- [ ] **Step 9: Review the commit series**

Run: `git log --oneline d828c01..HEAD`

Expected: one focused commit for each completed task, in plan order.

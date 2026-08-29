# Multi-Agent Native Adapters Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Host claude code, codex, and pi in the agent pane behind the fixed `AgentSessioning` UI, each as a native dialect adapter with resume.

**Architecture:** `AgentSessioning` (existing seam) stays the interface; `AgentRegistry` maps descriptors × availability → factories. `ACPClient`'s JSON-RPC core extracts to `JSONRPCChannel` (omp + codex); claude/pi use a lighter `LineChannel`. All four run over sessiond panes + `NdjsonSplitter`.

**Tech Stack:** Swift (AppKit GUI, Core = zero AppKit), sessiond unchanged, agent-web (TS) unchanged except store fields already present from the lossless-resume round.

**Spec:** `docs/superpowers/specs/2026-08-29-multi-agent-adapters-design.md` (wire facts, event mapping tables, risks). Fixtures: `swift-app/tools/fixtures/*.{jsonl}`.

## Global Constraints

- Core (`swift-app/Sources/Core/**`) must not import AppKit/Cocoa; UI stays in `Sources/UI` + `Sources/App`.
- sessiond untouched this milestone (cargo gates still run green).
- New Swift warnings = errors; `swift-app/build.sh` and `run-tests.sh` green.
- Integrity counters on every adapter (frames routed, events emitted, unparseable lines counted+logged, never silently dropped).
- No new npm/npx runtime dependencies.

## Task 1 — Generalize delegate + extract JSONRPCChannel

**Files:**
- Modify: `swift-app/Sources/Core/Agent/ACPTypes.swift` (delegate typed to `AgentSessioning`)
- Modify: `swift-app/Sources/Core/Agent/ACPClient.swift` → keep ACP method surface, move generic core to new file
- Create: `swift-app/Sources/Core/Agent/JSONRPCChannel.swift`
- Create: `swift-app/Sources/Core/Agent/LineChannel.swift`

**Interfaces (produced):**
```swift
final class JSONRPCChannel {          // id-multiplexed ndjson JSON-RPC
    init(write: @escaping (String) -> Void, onFrame: @escaping ([String: Any]) -> Void)
    func request(_ method: String, _ params: [String: Any]?, id: Int,
                 completion: @escaping ([String: Any]?) -> Void)
    func notify(_ method: String, _ params: [String: Any]?)
    func handleLine(_ line: String)   // feed from NdjsonSplitter
    func setRequestHandler(_ method: String, _ handler: @escaping ([String: Any], Int) -> [String: Any])
    var framesRouted / responsesMatched / serverRequestsHandled: Int  // audit
}
final class LineChannel {             // bare ndjson both ways (claude/pi)
    init(write: @escaping (String) -> Void, onFrame: @escaping ([String: Any]) -> Void)
    func send(_ frame: [String: Any])
    func handleLine(_ line: String)
    var framesRouted / unparseableLines: Int
}
protocol AgentSessionDelegate: AnyObject {
    func session(_ session: AgentSessioning, didEmit events: [AgentSessionEvent])
    func sessionDidFail(_ session: AgentSessioning, reason: String)
}
```
- [ ] Change delegate signatures to `AgentSessioning`; fix AgentSession/AgentPaneHost compile.
- [ ] Extract channel core; ACPClient becomes a JSONRPCChannel consumer with ACP methods (initialize/new/prompt/…). Behavior identical: agenttest green (replay-suppression tests unchanged).
- [ ] Add `setRequestHandler` (server→client requests) with a unit test.
- [ ] Commit: `refactor(agent): AgentSessioning-typed delegate, extract JSONRPCChannel/LineChannel`.

## Task 2 — AgentRegistry + renames

**Files:**
- Create: `swift-app/Sources/Core/Agent/AgentRegistry.swift`
- Modify: `AgentManifests.swift` (launch table moves out; detection manifests stay), `AppDelegate.swift`, `AppDelegate+AI.swift`, `AppDelegate+Menu.swift`, `Sidebar.swift`, `TabStripView.swift`, `LineTrigger.swift`, `AgentSession.swift` (factory param)

**Interfaces (produced):**
```swift
struct AgentDescriptor {
    let key: String; let label: String; let binary: String
    let argv: [String]; let ringBytes: Int
    let make: (AgentPaneParams) -> AgentSessioning   // params: paneId, cwd, env, daemon
    func availability(in path: [String]) -> Bool     // stat on PATH dirs, no spawn
}
enum AgentRegistry {
    static let descriptors: [AgentDescriptor]        // omp, claude, codex, pi order
    static func descriptor(for key: String) -> AgentDescriptor?
    static func availableKeys(path: [String]) -> [String]
}
```
- [ ] `lsp rename` ACPSessionSummary→AgentSessionSummary, ACPConfigOption→AgentConfigOption, ACPSlashCommand→AgentSlashCommand, ACPPermissionPrompt→AgentPermissionPrompt (ACPContent stays).
- [ ] Registry drives menus/pickers/triggers/restore; unavailable entries disabled with tooltip, still listed.
- [ ] omp entry keeps today's behavior byte-identical (same argv/ring).
- [ ] agenttest: registry table + availability hit/miss tests.
- [ ] Commit: `feat(agent): AgentRegistry with availability probing; dialect-neutral renames`.

## Task 3 — ClaudeSession

**Files:**
- Create: `swift-app/Sources/Core/Agent/Adapters/ClaudeSession.swift`
- Create: `swift-app/Sources/Core/Agent/Adapters/ClaudeFrameMapper.swift`
- Create: `swift-app/Sources/Core/Agent/Adapters/ClaudeSessionStore.swift`
- Test: `swift-app/tools/agenttest.swift` (+ fixture suites)

**Behavior:** spawn argv `claude --print --input-format stream-json --output-format stream-json --verbose [--model <m>] [--resume <sid>]`; send() writes user frame `{"type":"user","message":{"role":"user","content":[{"type":"text","text":…}]}}`; mapper: assistant text→messageChunk, tool_use/tool_result pairing→toolCallUpdate, result→turnEnded(+usage), system/init→ready+commands; control_request→permissionRequested, control_response written on respondPermission; store: `~/.claude/projects/<slug>/<sid>.jsonl` scan → AgentSessionSummary[]; load(sid) = reconnect with `--resume` + jsonl replay as history events; cancel = close stdin write half? (claude SDK: interrupt via control_request `{"type":"interrupt"}`? verify live; fallback: kill+respawn resume).
- [ ] Mapper unit tests on claude-oneshot/claude-resume fixtures (counts + text equality).
- [ ] Store test on a temp dir with synthetic jsonl.
- [ ] Live smoke via one-off sessiond pane: init ok, prompt "reply with exactly HELLO_CLAUDE" (explicit `--model`), transcript contains it; resume path loads fixture session.
- [ ] Commit: `feat(agent): claude code adapter (stream-json, resume via projects jsonl)`.

## Task 4 — CodexSession

**Files:**
- Create: `swift-app/Sources/Core/Agent/Adapters/CodexSession.swift`
- Create: `swift-app/Sources/Core/Agent/Adapters/CodexFrameMapper.swift`
- Test: `swift-app/tools/agenttest.swift`

**Behavior:** JSONRPCChannel over pane; initialize/initialized → thread/start → ready; turn/start per send(); item/started+item/completed → toolCallUpdate/assistantMessage→messageChunk (reasoning→thoughtChunk); turn/completed→turnEnded (status failed→sessionDidFail text); requestApproval handlers → permissionRequested + JSON-RPC response on answer; listSessions = `thread/list {limit, cwd}`; load = `thread/resume` + `thread/read {includeTurns:true}` replay; cancel = turn/interrupt? (verify; fallback `thread/interrupt` method else kill pane). model from `model/list` first text model when default is unusable (env quirk), descriptor modelArg override.
- [ ] Mapper unit tests on codex-appserver/codex-turn fixtures (userMessage echo, error reconnect frames, turn/completed failed).
- [ ] Live smoke: thread/start + turn/start with text model; approval path exercised if a command approval fires (else documented untested-live).
- [ ] Commit: `feat(agent): codex app-server adapter (thread lifecycle, approvals, thread/read resume)`.

## Task 5 — PiSession

**Files:**
- Create: `swift-app/Sources/Core/Agent/Adapters/PiSession.swift`
- Create: `swift-app/Sources/Core/Agent/Adapters/PiFrameMapper.swift`
- Create: `swift-app/Sources/Core/Agent/Adapters/PiSessionStore.swift`
- Test: `swift-app/tools/agenttest.swift`

**Behavior:** LineChannel over pane spawned `pi --mode rpc [--session <id>]`; send() = prompt command; message_update text_delta→messageChunk, thinking_delta→thoughtChunk, message_end(user)→userChunk, toolCall+toolResult pairing→toolCallUpdate, agent_settled→turnEnded, get_state→ready+configChanged(model) + usageUpdate from usage blocks; get_commands→commandsChanged; abort command for cancel; store: `~/.pi/agent/sessions/<slug>/*.jsonl` scan; load = spawn `--session` + get_messages replay; extension_ui_request ignored-but-counted.
- [ ] Mapper unit tests on pi-rpc/pi-resume fixtures (delta assembly equals message_end text).
- [ ] Store test synthetic dir.
- [ ] Live smoke: HELLO_PI + resume of the probe session (fixtures already prove shape).
- [ ] Commit: `feat(agent): pi rpc adapter (deltas, tool pairing, get_messages resume)`.

## Task 6 — E2E + regression sweep

- [ ] One-off-pane e2e for all four agents: connect → prompt → text present; pre-made session → list → load → history byte-equal (same audit standard as replayprobe; per-agent probe binary `swift-app/tools/agentprobe.swift`).
- [ ] `cargo fmt --check / clippy -D warnings / test` (sessiond untouched), `run-tests.sh`, `build.sh` — zero warnings.
- [ ] UI touch check: menus show 4 agents (disabled state for missing binaries), `@claude`/`@codex`/`@pi` triggers spawn correct panes.
- [ ] Final commit + summary.

## Self-review

- Spec coverage: registry/availability (T2), all three adapters + mappers + stores (T3-5), resume paths each, counters each, e2e gates (T6). Delegate/channel refactor = spec "Architecture". Renames = spec "Dialect-neutral renames". ✔
- Type consistency: AgentSessioning/AgentSessionEvent/ACPContent unchanged names used throughout; AgentPaneParams introduced T2, consumed T3-5 factories. ✔
- Placeholders: cancel/interrupt paths flagged verify-live (wire uncertainty, not laziness) with defined fallbacks. ✔

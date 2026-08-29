# Multi-Agent Native Adapters — Design

Date: 2026-08-29 · Branch: agent-gui · Predecessor: 2026-08-28-agent-gui-session-design.md (M1)

## Goal

Goty's agent pane hosts multiple coding agents behind ONE fixed UI. The
UI already speaks `AgentSessioning` + `AgentSessionEvent` (the M1 seam).
This design adds native adapters for **claude code**, **codex**, and
**pi** alongside omp, each implementing the same interface over its own
wire dialect, with first-class resume (list + load persisted sessions).

Strategy decision (user, 2026-08-29): **native adapters, paseo-style**
(reference: `~/Downloads/ai_project/paseo/packages/server/src/server/agent/`).
Zed ACP adapters (npx) were rejected: ACP has no session/list/load, so
resume would need native file readers anyway — two protocol stacks, plus
node/npx dependency.

## Non-goals

- No model pickers / mode-switch UI (configChanged channel stays; UI later).
- No omp behavior changes; `GOTY_AUTOLOAD_SESSION` stays omp-only.
- No subagent cards, no image rendering, no usage polling beyond what
  each protocol pushes for free.
- No SSH/remote agents (M2 scope).

## Architecture

```
UI (AgentPaneHost / agent-web / HistoryChip)  — unchanged
        ▲ AgentSessioning + AgentSessionEvent
┌───────┴────────────────────────────────────────────────┐
│ AgentRegistry: descriptors × availability → factories  │
├────────────┬─────────────┬─────────────┬───────────────┤
│ AgentSession│ClaudeSession│CodexSession │ PiSession     │
│ (ACP, omp) │ stream-json │ app-server  │ rpc           │
└────────────┴─────────────┴─────────────┴───────────────┘
        ▼ all four: sessiond pane (PTY no_echo ring) + NdjsonSplitter
```

- **`AgentSessioning` is the interface.** UI never learns which dialect
  runs underneath. Delegate generalizes from `AgentSession` to
  `AgentSessioning` (only breaking change inside Core).
- **`AgentRegistry`** replaces `AgentManifests.acpLaunch`: descriptor =
  key, label, binary, argv, ringBytes, availability probe, factory.
  Menus (`AppDelegate+Menu`, `Sidebar`, `TabStripView`), `@agent`
  triggers (`LineTrigger`) and restore path all read the registry.
- **Shared plumbing**: `ACPClient`'s JSON-RPC core (id multiplexing,
  pending table, notification routing, lock discipline) extracts to
  `JSONRPCChannel` — used by omp (ACP) and codex (app-server). Claude
  and pi use a lighter `LineChannel` (ndjson in/out, no ids required).
- **Dialect-neutral renames** (mechanical, `lsp rename`):
  `ACPSessionSummary→AgentSessionSummary`, `ACPConfigOption→
  AgentConfigOption`, `ACPSlashCommand→AgentSlashCommand`,
  `ACPPermissionPrompt→AgentPermissionPrompt`, `ACPContent` stays
  (it is the UI content currency), delegate `session(_:)` param type.

## Wire facts (recorded 2026-08-29, fixtures in `swift-app/tools/fixtures/`)

CLIs: omp 18.0.8, claude 2.1.133, codex 0.147.0, pi 0.84.3.

### omp (ACP — existing, unchanged)
`omp acp`; resume via omp's `session/list` + `session/load` extensions.

### claude (stream-json SDK mode)
Spawn: `claude --print --input-format stream-json --output-format
stream-json --verbose` (+`--resume <sid>` for load, `--model <m>`
override allowed). One line-JSON per frame both directions.
- In (we write): `{"type":"user","message":{"role":"user","content":
  [{"type":"text","text":"…"}]}}` — content array, NOT plain string.
- Out vocabulary: `system/init` (session_id, tools, slash_commands,
  permission modes), `system/hook_started|hook_response` (ignore),
  `assistant` (message.content[] blocks: text / tool_use{id,name,input}),
  `user` (tool_result blocks: tool_use_id, content, is_error),
  `stream_event` (partial deltas, only with --include-partial-messages —
  we do NOT pass it; whole-block granularity is enough), `result`
  (subtype success|error_*, is_error, session_id, num_turns, usage).
- Permissions: `control_request` frames `{"type":"control_request",
  "request_id","payload":{…can_use_tool…}}`; we answer
  `{"type":"control_response","response_id","payload":{"behavior":
  "allow"|"deny", "updatedInput":…}}`. Fixture lacks one (env model
  broken); shape pinned from paseo `providers/claude/agent.ts` and
  verified live during adapter e2e.
- Turn end: `result` frame ⇒ turnEnded; `is_error=true` ⇒ failure text.
- Sessions: `~/.claude/projects/<path-slug>/<session_id>.jsonl`
  (one JSON line per SDK message; 9 lines for our 2-turn probe).
  listSessions = scan that dir filtered by cwd slug; load = spawn with
  `--resume <sid>`; history replay = parse the jsonl (same message
  vocabulary as live frames) → userChunk/messageChunk/toolCallUpdate.
- Known env quirk (this machine): default model `claude-sonnet-5`
  errors; e2e passes explicit `--model`.

### codex (app-server JSON-RPC)
Spawn: `codex app-server`. Standard JSON-RPC ndjson (same envelope as
ACPClient: `{id,method,params}` / `{id,result|error}` / `{method,params}`).
- Handshake: req `initialize {clientInfo{name,version}}` → resp; then
  notify `initialized {}`.
- `thread/start {cwd}` → `result.thread{id, path, cwd, model…}` (also
  notifies `thread/started`). `turn/start {threadId, input:[{type:"text",
  text}]}` → `result.turn{id,status}` (threadId must be the string id;
  null → -32600).
- Notifications: `turn/started`, `turn/completed` (turn.status
  completed|failed + error), `item/started` + `item/completed` with
  `item.type`: `userMessage` (content[]), `assistantMessage` (content[]),
  `commandExecution`, `fileChange`, `reasoning`, … `thread/status/changed`
  (idle|active|systemError), `error` (willRetry, codexErrorInfo), `warning`,
  `mcpServer/startupStatus/updated` (ignore).
- Approvals (server→client REQUESTS): `item/commandExecution/requestApproval`,
  `item/fileChange/requestApproval`, `item/tool/requestUserInput` (+
  legacy `tool/requestUserInput`); respond `{decision:…}` per kind
  (verified live during adapter e2e; envelope is JSON-RPC response with
  the request's id — JSONRPCChannel already supports server requests? NO:
  add `setRequestHandler` to the channel).
- Resume: `thread/list {limit, cwd?}` → `data[{id, preview, cwd,
  updatedAt, path…}]`; `thread/resume {threadId,…}` + `thread/read
  {threadId, includeTurns:true}` → turns[].items[] (same item vocabulary
  as live) — history replay without file parsing.
- Known env quirk (this machine): relay default model `gpt-image-2`
  404s on text; e2e picks a text model from `model/list`.

### pi (rpc)
Spawn: `pi --mode rpc` (+`--session <id>` to resume). ndjson both ways.
- Commands (we write, optional id): `{"id","type":"prompt","message"} `,
  `{"type":"abort"}`, `{"type":"get_state"}`, `{"type":"get_messages"}`,
  `{"type":"set_model","provider","modelId"}`, `{"type":"get_commands"}`…
  Responses: `{"id","type":"response","command","success","data|error"}`.
- Events: `agent_start`, `turn_start`, `message_start`/`message_end`
  (message.role user|assistant, content[] blocks: text / thinking /
  toolCall{id,name,arguments} — user messages echo our prompt),
  `message_update` (assistantMessageEvent: text_start/text_delta/text_end/
  thinking_start/thinking_delta/thinking_end with contentIndex), `turn_end`,
  `agent_end` (full messages[]), `agent_settled`, `toolResult` arrives as
  a message (role toolResult: toolCallId, toolName, content, isError).
- `extension_ui_request` frames (setStatus/setWidget/notify — pi
  extensions): ignored in v1 (counted, not dropped silently).
- get_state data: sessionId, sessionFile, model{id,provider}, isStreaming,
  messageCount, contextUsage. usageUpdate maps from message usage blocks.
- Sessions: `~/.pi/agent/sessions/<path-slug>/*.jsonl` (omp layout).
  listSessions = scan dir; load = spawn `--session <id>` then
  `get_messages` → replay (verified live: full history returns).
- Permissions: pi rpc auto-approves tools per its config; v1 surfaces
  nothing. (rpc-ui mode exists for UI requests — out of scope.)

## Event mapping (dialect → AgentSessionEvent)

| AgentSessionEvent | claude | codex | pi |
|---|---|---|---|
| ready | system/init | initialize+thread/start ok | get_state ok |
| userChunk | history jsonl user msgs | item userMessage (replay) | message_end role=user (replay) |
| messageChunk | assistant text blocks (live+history) | item assistantMessage deltas/complete | message_update text_delta |
| thoughtChunk | (none — thinking not in stream-json v1) | item reasoning | message_update thinking_delta |
| toolCallUpdate | tool_use blocks + matching tool_result | item commandExecution/fileChange/… start+complete | toolCall blocks + toolResult messages |
| plan | ExitPlanMode tool_use → permission kind plan | item plan? (none v1) | (none v1) |
| permissionRequested | control_request can_use_tool | requestApproval requests | (none v1) |
| turnEnded | result frame | turn/completed | agent_settled |
| configChanged | system/init slash_commands→commands; model list static | model/list→model option | get_state model + get_commands |
| commandsChanged | system/init slash_commands | (none v1) | get_commands |
| usageUpdate | result.usage | (none pushed; skip) | message usage blocks |

Replay rule (all agents, mirrors omp): history events arrive with
`replay: true` semantics — bridge/store treat them identically to live
frames (transcript rebuild); the session suppresses duplicate local echo.

## Failure & audit

- Every adapter keeps the M1 integrity counters (bytes fed, frames
  routed, events emitted, bridge pushed/delivered, store applied/
  rejected). Adapter-level counters land in the same debug dump.
- Process death (daemon EXITED frame) → sessionDidFail with the
  dialect's last error text if any (claude result.is_error, codex
  turn/completed.error / thread status systemError, pi response.error).
- Unparseable lines: counted + logged, never silently dropped (64MB
  garbage guard already in NdjsonSplitter).

## Availability

`AgentRegistry.availability` probes `UserShellEnv` PATH for the
descriptor's binary (`which`-equivalent via `stat` on PATH dirs — no
subprocess spawn per probe), cached at app start + on workspace focus.
Menu items render disabled with a tooltip ("claude 不在 PATH") instead of
silently missing. Picker order: omp, claude, codex, pi.

## Testing

- Unit: per-dialect frame→event mappers run against the recorded
  fixtures (claude-oneshot/resume, codex-appserver/turn, pi-rpc/resume);
  store-reader unit tests with synthetic dirs.
- agenttest.swift gains: registry table test, three mapper suites,
  availability probe test (PATH hit + miss).
- E2E (real CLIs, one-off pane like replayprobe): spawn → handshake →
  "reply HELLO_X" → transcript contains it; resume: pre-made session →
  listSessions sees it → load replays history (byte-equal text fields,
  same standard as the omp replayprobe audit).
- Gates: cargo fmt/clippy/test (sessiond untouched), run-tests.sh,
  build.sh zero warnings.

## Risks

- **Protocol drift**: adapters bind loosely (unknown fields ignored),
  fixtures pin the shapes we rely on; drift caught by e2e.
- **claude/codex broken default models on THIS machine**: e2e overrides
  models; descriptor carries optional `modelArg` for envs like this.
- **PTY vs pipe**: all four CLIs verified over pipes; sessiond panes are
  PTYs — omp already proves ndjson-over-PTY works (ONLCR `\r\n` trimmed
  by NdjsonSplitter's line parser; claude/codex/pi get the same trim).

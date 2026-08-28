# Agent GUI Session — M1 (omp 端到端) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新建 space 可选「Agent Session (GUI)」：本地 `omp acp` 以无头进程跑在 sessiond PTY 里，Goty.app 用 WKWebView 渲染 ACP 转录，支持发送/流式渲染/审批/停止，GUI 重开后由 replay ring 重建转录。

**Architecture:** agent 进程 = sessiond 托管的普通 pane 进程，ndjson JSON-RPC 复用现有 frame 字节通道（sessiond 不理解 ACP）。Swift 侧 `Core/Agent`（零 AppKit）承载 ACP 子集客户端；`UI/Agent/AgentPaneHost` 用 WKWebView + 原生 composer 渲染；`agent-web/`（Vite+React）为本地静态资产。

**Tech Stack:** Rust (portable-pty) / Swift AppKit + WebKit / Vite + React + react-markdown。

**Spec:** `docs/superpowers/specs/2026-08-28-agent-gui-session-design.md`（执行者须先读）

## Global Constraints

- Core（`Sources/Core`）零 AppKit import；所有新 UI 在 `Sources/UI`。
- 检查（提交前必跑）：`cargo fmt --manifest-path swift-app/sessiond/Cargo.toml -- --check`；`cargo clippy --manifest-path swift-app/sessiond/Cargo.toml --all-targets -- -D warnings`；`cargo test --manifest-path swift-app/sessiond/Cargo.toml`；`swift-app/run-tests.sh`；最终 `swift-app/build.sh` 成功。新 Swift warning 视为错误。
- 绝不 `pkill -f ".../MacOS/goty"`（会误杀 goty-sessiond）；重启 GUI 用 `swift-app/restart-app.sh`。
- ACP 子集（M1 只实现这些）：`initialize`、`session/new`、`session/prompt`、`session/cancel`、`session/request_permission`（server→client 请求 + 应答）、`session/update`（`agent_message_chunk` / `agent_thought_chunk` / `tool_call` / `tool_call_update` / `plan`）。
- 常量：agent pane ring 容量 64 MiB（`67_108_864`）；ndjson 单行上限 1 MiB；echo 过滤环 32 条。
- 首批只接 omp：`AgentManifests` 仅 `omp → ("omp", ["acp"], 64 MiB)`。
- `CAPABILITY` 3→4；`SessionDaemon.expectedCapability` **保持 3** 不动（旧 daemon 仍可服务终端），agent 入口单独用 `supportsAgentSessions()`（≥4）判断。

---

### Task 1: sessiond — ring 容量参数 + no_echo + CAPABILITY 4

**Files:**
- Modify: `swift-app/sessiond/src/protocol.rs`（SpawnRequest、CAPABILITY）
- Modify: `swift-app/sessiond/src/pane.rs`（ReplayRing、Pane::spawn、tests）
- Modify: `swift-app/sessiond/src/main.rs`（若有 SpawnRequest 字面量则补字段；integration.rs 同查）

**Interfaces:**
- Produces: `SpawnRequest { ..., no_echo: bool, ring_bytes: Option<u64> }`（serde default，向后兼容）；`ReplayRing::new(size: WinSize, cap: usize)`；`pane::echo_off_wrapper(shell: &str, args: &[String]) -> (String, Vec<String>)`。Swift 侧 Task 2 依赖这两个 JSON 键：`"no_echo"`、`"ring_bytes"`。

- [ ] **Step 1: 写失败测试（Rust）**

在 `pane.rs` tests mod 中加入（并在 Task 内同步修改现有 `ReplayRing::new(size(..))` 调用为带 `RING_CAP`，否则编译失败即"失败"）：

```rust
    #[test]
    fn ring_honors_custom_capacity() {
        let mut ring = ReplayRing::new(size(80), 16);
        ring.append(b"aaaaaaaaaaaaaaaa"); // 16 bytes: 恰好满
        ring.append(b"bbbb");
        assert_eq!(ring.len, 16);
        let (tx, rx) = mpsc::sync_channel(8);
        assert!(ring.replay(&tx));
        drop(tx);
        let bytes: Vec<u8> = rx.into_iter().flat_map(|f| f.payload).collect();
        assert_eq!(bytes, b"aaaaaaaaaaaabbbb".to_vec()); // 最新的 16 字节
    }

    #[test]
    fn echo_off_wrapper_quotes_arguments() {
        let (shell, args) = echo_off_wrapper("omp", &["acp"]);
        assert_eq!(shell, "/bin/sh");
        assert_eq!(args[0], "-c");
        assert_eq!(args[1], "stty -echo 2>/dev/null; exec 'omp' 'acp'");
        let (_, args) = echo_off_wrapper("/usr/local/bin/claude", &["-r", "it's id"]);
        assert!(args[1].contains(r"'it'\''s id'"));
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cargo test --manifest-path swift-app/sessiond/Cargo.toml pane::tests`
Expected: 编译失败（`ReplayRing::new` 参数不匹配 / `echo_off_wrapper` 未定义）。

- [ ] **Step 3: 实现**

`protocol.rs`：`pub const CAPABILITY: u8 = 4;`（注释追加：`4 = SpawnRequest.no_echo + ring_bytes`）。`SpawnRequest` 追加：

```rust
    /// Agent sessions: run the command under `sh -c 'stty -echo; exec …'`
    /// — agent CLIs do not manage termios, and PTY echo would corrupt the
    /// ndjson stream. Requires CAPABILITY 4.
    #[serde(default)]
    pub no_echo: bool,
    /// Replay-ring capacity override in bytes (agent sessions: 64 MiB so
    /// long transcripts survive attach); None = RING_CAP. Requires
    /// CAPABILITY 4.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ring_bytes: Option<u64>,
```

`pane.rs`：`struct ReplayRing` 加 `cap: usize`；`fn new(size: WinSize, cap: usize)` 存下；`append` 中 `RING_CAP` 全部换成 `self.cap`（>= 判断、slice 尾部、`self.len = self.cap`、overflow 循环）。`Pane::spawn`：

```rust
        let (shell, args) = if request.no_echo {
            echo_off_wrapper(&request.shell, &request.args)
        } else {
            (request.shell.clone(), request.args.clone())
        };
        let mut command = CommandBuilder::new(&shell);
        command.args(&args);
```

ring 构造：

```rust
                ring: ReplayRing::new(
                    size,
                    request
                        .ring_bytes
                        .map(|b| (b as usize).clamp(64 * 1024, 256 * 1024 * 1024))
                        .unwrap_or(RING_CAP),
                ),
```

文件底部（`unwrap_runtime_argv` 附近）加：

```rust
/// Agent panes need ECHO off (agent CLIs never manage termios). Rather
/// than reaching for the master fd, run the command under `sh -c`: stty
/// executes inside the pty itself, then exec replaces the shell. The
/// client's echo filter (ACPClient.recentOut) tolerates the µs window
/// before stty lands.
fn echo_off_wrapper(shell: &str, args: &[String]) -> (String, Vec<String>) {
    fn quote(token: &str) -> String {
        format!("'{}'", token.replace('\'', "'\\''"))
    }
    let mut line = String::from("stty -echo 2>/dev/null; exec ");
    line.push_str(&quote(shell));
    for arg in args {
        line.push(' ');
        line.push_str(&quote(arg));
    }
    ("/bin/sh".to_string(), vec!["-c".to_string(), line])
}
```

同步修掉所有 `SpawnRequest {` 字面量（`main.rs` tests、`integration.rs`）：补 `no_echo: false, ring_bytes: None,`；所有 `ReplayRing::new(` 单参调用补 `RING_CAP`。先 `grep -n "ReplayRing::new(\|SpawnRequest {" swift-app/sessiond/src`。

- [ ] **Step 4: 跑测试确认通过**

Run: `cargo test --manifest-path swift-app/sessiond/Cargo.toml`
Expected: 全部 PASS（含旧测试）。

- [ ] **Step 5: fmt + clippy + commit**

Run: `cargo fmt --manifest-path swift-app/sessiond/Cargo.toml && cargo clippy --manifest-path swift-app/sessiond/Cargo.toml --all-targets -- -D warnings`

```bash
git add swift-app/sessiond/src
git commit -m "feat(sessiond): per-spawn ring capacity + no-echo agent panes (CAPABILITY 4)"
```

---

### Task 2: Swift daemon — spawn 参数透传 + capability 探测 + agenttest 骨架

**Files:**
- Modify: `swift-app/Sources/Core/Workspace/SessionDaemon.swift`
- Create: `swift-app/tools/agenttest.swift`
- Modify: `swift-app/run-tests.sh`（注册 agenttest）

**Interfaces:**
- Produces: `SessionDaemon.openPane(id:cwd:shell:args:environment:grid:noEcho:ringBytes:onFrame:onDisconnect:) -> PaneSession?`（新参数带默认值，旧调用零改动）；`static func agentSpawnPayload(cwd:shell:args:environment:grid:noEcho:ringBytes:) -> [String: Any]`（纯函数，供测试）；`static func supportsAgentSessions() -> Bool`。

- [ ] **Step 1: 抽出纯函数 + 加参数**

`openPane` 里 spawn 分支的 request 字典抽成静态纯函数：

```swift
    /// SpawnRequest JSON (sessiond protocol.rs). noEcho/ringBytes require
    /// CAPABILITY 4; older daemons ignore them via serde defaults — callers
    /// gate on supportsAgentSessions() instead of relying on that.
    static func agentSpawnPayload(cwd: String?, shell: String, args: [String],
                                  environment: [String: String], grid: SessionGrid,
                                  noEcho: Bool, ringBytes: UInt64?) -> [String: Any] {
        var request: [String: Any] = [
            "pane_id": "", // caller overwrites; kept for a single shape
            "cwd": cwd ?? NSNull(),
            "shell": shell,
            "args": args,
            "env": environment.map { [$0.key, $0.value] },
            "size": [
                "cols": grid.columns, "rows": grid.rows,
                "cell_w": grid.cellWidth, "cell_h": grid.cellHeight,
            ],
            "replay": true,
        ]
        if noEcho { request["no_echo"] = true }
        if let ringBytes { request["ring_bytes"] = ringBytes }
        return request
    }
```

`openPane` 签名追加 `noEcho: Bool = false, ringBytes: UInt64? = nil`，spawn 分支改为：

```swift
            var request = Self.agentSpawnPayload(cwd: cwd, shell: shell, args: args,
                                                 environment: environment, grid: grid,
                                                 noEcho: noEcho, ringBytes: ringBytes)
            request["pane_id"] = id
            guard let data = try? JSONSerialization.data(withJSONObject: request),
```

（`pane_id` 在函数内联进 payload；attach 分支不变。）

capability 探测（`expectedCapability` 保持 3）：

```swift
    /// Agent GUI sessions need the CAPABILITY-4 daemon (no_echo +
    /// ring_bytes). nil capability = not running — ensureRunning first.
    static func supportsAgentSessions() -> Bool {
        guard shared.ensureRunning() else { return false }
        return (sharedRunningCapability() ?? 0) >= 4
    }
```

- [ ] **Step 2: 建 agenttest 骨架并注册**

`swift-app/tools/agenttest.swift`（照 settingstest.swift 的模式，头部注释 + `@testable import goty`；本任务先放 payload 测试，后续任务追加段落）：

```swift
// agenttest.swift — headless contract tests for Core/Agent (ACP).
//
// Built and run by run-tests.sh; NOT part of the app binary.
import Foundation
@testable import goty

@main
enum AgentTest {
    static func main() {
        var failures = 0
        func check(_ cond: Bool, _ name: String) {
            if cond { print("  ok  \(name)") } else { failures += 1; print("FAIL  \(name)") }
        }

        print("— agentSpawnPayload —")
        let grid = SessionGrid(columns: 120, rows: 40, cellWidth: 8, cellHeight: 16)
        let payload = SessionDaemon.agentSpawnPayload(
            cwd: "/tmp", shell: "omp", args: ["acp"],
            environment: ["PATH": "/usr/bin"], grid: grid,
            noEcho: true, ringBytes: 67_108_864)
        check(payload["no_echo"] as? Bool == true, "no_echo=true present")
        check(payload["ring_bytes"] as? UInt64 == 67_108_864, "ring_bytes present")
        check((payload["args"] as? [String]) == ["acp"], "args pass through")
        let plain = SessionDaemon.agentSpawnPayload(
            cwd: nil, shell: "/bin/zsh", args: ["-l"], environment: [:],
            grid: grid, noEcho: false, ringBytes: nil)
        check(plain["no_echo"] == nil && plain["ring_bytes"] == nil,
              "terminal panes serialize without the new keys")

        if failures > 0 { exit(1) }
        print("agenttest: all passed")
    }
}
```

`run-tests.sh`：编译循环 `for t in layouttest filestest settingstest aitest` 改为 `... aitest agenttest`；顺序运行段 `run_guarded "$B"/goty-aitest-test` 之后加 `run_guarded "$B"/goty-agenttest-test`。

- [ ] **Step 3: 跑测试**

Run: `swift-app/run-tests.sh`
Expected: 五个入口全绿，`goty-agenttest-test` PASS。
（若 agenttest 因缓存未编译进模块：删除 `/tmp/goty-test-cache-$(id -u)` 后重跑。）

- [ ] **Step 4: Commit**

```bash
git add swift-app/Sources/Core/Workspace/SessionDaemon.swift swift-app/tools/agenttest.swift swift-app/run-tests.sh
git commit -m "feat(daemon): no_echo/ring_bytes spawn params + agent session capability probe + agenttest harness"
```

---

### Task 3: Core/Agent — NdjsonSplitter + ACPClient（含 echo 过滤）

**Files:**
- Create: `swift-app/Sources/Core/Agent/NdjsonSplitter.swift`
- Create: `swift-app/Sources/Core/Agent/ACPClient.swift`
- Modify: `swift-app/tools/agenttest.swift`

**Interfaces:**
- Produces:
  - `struct NdjsonSplitter { mutating func feed(_ bytes: [UInt8]) -> [String] }`
  - `final class ACPClient`：`var onNotification: ((String, [String: Any]) -> Void)?`；`var onRequest: ((Int, String, [String: Any]) -> Void)?`；`var onOutbound: (([UInt8]) -> Void)?`；`func feed(_ bytes: [UInt8])`；`@discardableResult func request(_ method: String, _ params: [String: Any], completion: @escaping (Result<[String: Any], String>) -> Void) -> Int`；`func notify(_ method: String, _ params: [String: Any])`；`func respond(id: Int, result: [String: Any])`。
- Consumes: 无（纯 Foundation）。

- [ ] **Step 1: 写失败测试（追加到 agenttest.swift 的 main() 内）**

```swift
        print("— NdjsonSplitter —")
        var splitter = NdjsonSplitter()
        check(splitter.feed(Array("{\"a\":1}\n".utf8)) == ["{\"a\":1}"], "single line")
        check(splitter.feed(Array("{\"b\"".utf8)).isEmpty, "partial line buffered")
        check(splitter.feed(Array("}\n{\"c\":3}\n".utf8)) == ["{\"b\"}", "{\"c\":3}"],
              "split across chunks")
        check(splitter.feed(Array("x\r\ny\n".utf8)) == ["x", "y"], "CRLF trimmed")

        print("— ACPClient echo filter + routing —")
        let client = ACPClient()
        var notifications: [(String, [String: Any])] = []
        client.onNotification = { notifications.append(($0, $1)) }
        var outbound: [[UInt8]] = []
        client.onOutbound = { outbound.append($0) }
        var got: Result<[String: Any], String>?
        client.request("initialize", ["protocolVersion": 1]) { got = $0 }
        let sentLine = String(decoding: outbound[0], as: UTF8.self)
        // stty 竞态窗口的回显：逐字节原样回来，必须被丢弃且不影响 pending
        client.feed(Array(sentLine.utf8))
        check(notifications.isEmpty, "echoed request dropped")
        client.feed(Array("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":1}}\n".utf8))
        check(got?.isSuccess == true, "pending request completed")
        client.notify("session/cancel", ["sessionId": "s1"])
        client.feed(Array("{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"s1\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"hi\"}}}}\n".utf8))
        check(notifications.count == 1 && notifications[0].0 == "session/update",
              "notification routed")
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift-app/run-tests.sh`
Expected: FAIL（类型未定义，编译失败）。

- [ ] **Step 3: 实现 NdjsonSplitter.swift**

```swift
// goty — see CLAUDE.md for the working principles.
import Foundation

/// Incremental ndjson line splitter over the agent pane's byte stream.
/// Lines may straddle chunk boundaries; an over-long line (no \n within
/// 1 MiB) is discarded whole — it cannot be valid ACP traffic.
struct NdjsonSplitter {
    private var buffer: [UInt8] = []
    private static let maxLine = 1024 * 1024

    mutating func feed(_ bytes: [UInt8]) -> [String] {
        buffer.append(contentsOf: bytes)
        var lines: [String] = []
        var start = 0
        for i in buffer.indices where buffer[i] == 0x0A {
            var line = buffer[start..<i]
            if line.last == 0x0D { line = line.dropLast() }
            if let text = String(bytes: line, encoding: .utf8), !text.isEmpty {
                lines.append(text)
            }
            start = i + 1
        }
        buffer.removeSubrange(..<start)
        if buffer.count > Self.maxLine { buffer.removeAll(keepingCapacity: true) }
        return lines
    }
}
```

- [ ] **Step 4: 实现 ACPClient.swift**

```swift
// goty — see CLAUDE.md for the working principles.
import Foundation

/// JSON-RPC 2.0 over ndjson for one agent pane. Inbound traffic is
/// loosely typed ([String: Any]) on purpose: the M1 ACP subset is small
/// and the schema is still moving (v1/v2); AgentSession owns the typed
/// extraction. Outbound goes through onOutbound → PaneSession.sendInput.
///
/// Echo filter: the no-echo stty runs inside the pty microseconds after
/// fork; anything we write before it lands can come back verbatim. The
/// last 32 outbound lines are ring-buffered and dropped on sight.
final class ACPClient {
    var onNotification: ((String, [String: Any]) -> Void)?
    /// server→client request (session/request_permission)
    var onRequest: ((Int, String, [String: Any]) -> Void)?
    var onOutbound: (([UInt8]) -> Void)?

    private var nextID = 1
    private var pending: [Int: (Result<[String: Any], String>) -> Void] = [:]
    private var recentOut: [String] = []
    private var splitter = NdjsonSplitter()
    private static let echoRing = 32

    func feed(_ bytes: [UInt8]) {
        for line in splitter.feed(bytes) {
            if recentOut.contains(line) { continue }
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data),
                  let message = json as? [String: Any] else { continue }
            route(message, line: line)
        }
    }

    private func route(_ message: [String: Any], line: String) {
        if let method = message["method"] as? String {
            let params = message["params"] as? [String: Any] ?? [:]
            if let id = message["id"] as? Int {
                onRequest?(id, method, params)
            } else {
                onNotification?(method, params)
            }
            return
        }
        // A response: complete the pending request. An echo that somehow
        // passed the exact-match filter lands here without a pending id.
        guard let id = message["id"] as? Int, let completion = pending.removeValue(forKey: id)
        else { return }
        if let error = message["error"] as? [String: Any],
           let text = error["message"] as? String {
            completion(.failure(text))
        } else if let result = message["result"] as? [String: Any] {
            completion(.success(result))
        } else {
            completion(.success([:]))
        }
        _ = line
    }

    @discardableResult
    func request(_ method: String, _ params: [String: Any],
                 completion: @escaping (Result<[String: Any], String>) -> Void) -> Int {
        let id = nextID
        nextID += 1
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        pending[id] = completion
        return id
    }

    func notify(_ method: String, _ params: [String: Any]) {
        send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    /// Answer a server→client request (permission outcome).
    func respond(id: Int, result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        let bytes = Array(line.utf8)
        recentOut.append(line)
        if recentOut.count > Self.echoRing { recentOut.removeFirst(recentOut.count - Self.echoRing) }
        onOutbound?(bytes)
    }
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `swift-app/run-tests.sh`
Expected: agenttest 全绿。

- [ ] **Step 6: Commit**

```bash
git add swift-app/Sources/Core/Agent swift-app/tools/agenttest.swift
git commit -m "feat(agent): ndjson splitter + JSON-RPC client with pty-echo filter"
```

---

### Task 4: Core/Agent — ACP 类型提取 + AgentSession 状态机 + omp manifest

**Files:**
- Create: `swift-app/Sources/Core/Agent/ACPTypes.swift`
- Create: `swift-app/Sources/Core/Agent/AgentSession.swift`
- Modify: `swift-app/Sources/Core/Agents/AgentManifests.swift`
- Modify: `swift-app/tools/agenttest.swift`

**Interfaces:**
- Consumes: `ACPClient`（Task 3）；`SessionDaemon.openPane(... noEcho:ringBytes:)`（Task 2）。
- Produces:
  - `struct ACPContent { type: String; text: String?; path: String? }`、`struct ACPPlanEntry { content: String; priority: String?; status: String? }`、`struct ACPOption { optionId: String; name: String; kind: String? }`、`struct ACPPermissionPrompt { requestID: Int; toolCallTitle: String?; options: [ACPOption] }`
  - `enum AgentSessionEvent { case ready; case messageChunk(String); case thoughtChunk(String); case toolCallUpdate(id: String, title: String?, kind: String?, status: String?, content: [ACPContent]); case plan([ACPPlanEntry]); case permissionRequested(ACPPermissionPrompt); case turnEnded(stopReason: String?) }`
  - `protocol AgentSessionDelegate: AnyObject { func session(_ session: AgentSession, didEmit events: [AgentSessionEvent]); func sessionDidFail(_ session: AgentSession, reason: String) }`
  - `final class AgentSession { init(paneId: String, cwd: String?, grid: SessionGrid, environment: [String: String], launch: AgentManifests.ACPLaunch, daemon: SessionDaemon, delegate: ...); func connect(completion: @escaping (Bool) -> Void); func send(_ text: String); func cancel(); func respondPermission(requestID: Int, optionId: String); func shutdown(); var isWorking: Bool }`（connect 内部做 initialize → session/new）
  - `struct AgentManifests.ACPLaunch { let command: String; let args: [String]; let ringBytes: UInt64 }`；`static func acpLaunch(for key: String) -> ACPLaunch?`（仅 `"omp"`）；`static let acpPickerOrder: [(key: String, label: String)]`（`[("omp", "omp")]`）。
  - AgentSessionEvent 与 `AgentActivity` 的映射由 Task 7 在 coordinator 做，本任务不碰 coordinator。

- [ ] **Step 1: 写失败测试（追加 agenttest）**

```swift
        print("— AgentSession.interpret —")
        var events: [AgentSessionEvent] = []
        let daemon = SessionDaemon(socketPath: "/nonexistent-\(UUID().uuidString)")
        let session = AgentSession(paneId: "p1", cwd: nil, grid: grid,
                                   environment: [:],
                                   launch: AgentManifests.ACPLaunch(
                                       command: "omp", args: ["acp"],
                                       ringBytes: 67_108_864),
                                   daemon: daemon, delegate: nil)
        session.interpret(["method": "session/update", "params": [
            "sessionId": "s1",
            "update": ["sessionUpdate": "agent_message_chunk",
                       "content": ["type": "text", "text": "hello"]],
        ]])
        session.interpret(["method": "session/update", "params": [
            "sessionId": "s1",
            "update": ["sessionUpdate": "tool_call", "toolCallId": "t1",
                       "title": "Read file", "kind": "read", "status": "completed",
                       "content": [["type": "text", "text": "src/main.rs"]]],
        ]])
        session.interpret(["method": "session/update", "params": [
            "sessionId": "s1",
            "update": ["sessionUpdate": "plan",
                       "entries": [["content": "step 1", "priority": "high", "status": "pending"]]],
        ]])
        session.interpret(["id": 7, "method": "session/request_permission", "params": [
            "sessionId": "s1", "toolCall": ["title": "bash"],
            "options": [["optionId": "allow", "name": "Allow", "kind": "allow_once"]],
        ]])
        check(events.count == 4, "four events interpreted")
        if case .messageChunk(let text)? = events.first, text == "hello" {} else { failures += 1; print("FAIL  messageChunk payload") }
        if case .toolCallUpdate(let id, _, _, let status, let content)? = events.dropFirst().first,
           id == "t1", status == "completed", content.count == 1 {} else { failures += 1; print("FAIL  toolCallUpdate payload") }
        if case .permissionRequested(let prompt)? = events.last, prompt.requestID == 7,
           prompt.options.first?.optionId == "allow" {} else { failures += 1; print("FAIL  permission prompt") }

        print("— manifest —")
        let launch = AgentManifests.acpLaunch(for: "omp")
        check(launch?.command == "omp" && launch?.args == ["acp"], "omp acp launch")
        check(AgentManifests.acpLaunch(for: "claude") == nil, "v1 is omp-only")
```

（`AgentSession.interpret` 需为 `internal` 且 delegate 可为 nil——事件照常产出，方便测试；`delegate` 用 weak 数组还是单值：单值，nil 合法。）

- [ ] **Step 2: 跑测试确认失败**

Run: `swift-app/run-tests.sh` — Expected: 编译失败。

- [ ] **Step 3: 实现 ACPTypes.swift**

```swift
// goty — see CLAUDE.md for the working principles.
import Foundation

/// Hand-written M1 subset of the ACP content shapes (spec: Risk — ACP
/// v2 drift; we bind to v1 only, loosely, and ignore unknown fields).
struct ACPContent {
    let type: String
    let text: String?
    let path: String?

    init?(_ raw: [String: Any]) {
        guard let type = raw["type"] as? String else { return nil }
        self.type = type
        self.text = raw["text"] as? String
        self.path = raw["path"] as? String
    }
}

struct ACPPlanEntry {
    let content: String
    let priority: String?
    let status: String?

    init?(_ raw: [String: Any]) {
        guard let content = raw["content"] as? String else { return nil }
        self.content = content
        self.priority = raw["priority"] as? String
        self.status = raw["status"] as? String
    }
}

struct ACPOption {
    let optionId: String
    let name: String
    let kind: String?
}

struct ACPPermissionPrompt {
    let requestID: Int
    let toolCallTitle: String?
    let options: [ACPOption]
}
```

- [ ] **Step 4: 实现 AgentSession.swift**

```swift
// goty — see CLAUDE.md for the working principles.
import Foundation

/// One GUI agent session: an ACP-speaking agent process hosted by
/// sessiond (attach-or-spawn), driven over the shared frame channel.
/// State machine: disconnected → connecting → ready ⇄ working /
/// awaitingPermission; death surfaces as the daemon's EXITED frame.
final class AgentSession {
    weak var delegate: AgentSessionDelegate?

    private let paneId: String
    private let cwd: String?
    private let environment: [String: String]
    private let launch: AgentManifests.ACPLaunch
    private let daemon: SessionDaemon
    private let grid: SessionGrid
    private var pane: PaneSession?
    private let client = ACPClient()
    private(set) var sessionId: String?
    private(set) var isWorking = false
    private var connected = false

    init(paneId: String, cwd: String?, grid: SessionGrid,
         environment: [String: String],
         launch: AgentManifests.ACPLaunch, daemon: SessionDaemon,
         delegate: AgentSessionDelegate? = nil) {
        self.paneId = paneId
        self.cwd = cwd
        self.grid = grid
        self.environment = environment
        self.launch = launch
        self.daemon = daemon
        self.delegate = delegate
        client.onOutbound = { [weak self] in self?.pane?.sendInput($0) }
        client.onNotification = { [weak self] method, params in
            self?.interpret(["method": method, "params": params])
        }
        client.onRequest = { [weak self] id, method, params in
            guard method == "session/request_permission" else { return }
            self?.interpret(["id": id, "method": method, "params": params])
        }
    }

    /// Agent panes are line-agnostic; the grid only exists because the
    /// daemon sizes every PTY. Fixed sane defaults; resize is never sent.
    static let fixedGrid = SessionGrid(columns: 120, rows: 40, cellWidth: 8, cellHeight: 16)

    func connect(completion: ((Bool) -> Void)? = nil) {
        guard !connected else { return completion?(true) }
        connected = true
        pane = daemon.openPane(
            id: paneId, cwd: cwd, shell: launch.command, args: launch.args,
            environment: environment, grid: grid,
            noEcho: true, ringBytes: launch.ringBytes,
            onFrame: { [weak self] kind, data in
                self?.handleFrame(kind: kind, data: data)
            },
            onDisconnect: { [weak self] in
                guard let self else { return }
                self.connected = false
                self.delegate?.sessionDidFail(self, reason: "daemon 连接断开")
            })
        guard pane != nil else {
            connected = false
            delegate?.sessionDidFail(self, reason: "sessiond 不可用")
            return completion?(false)
        }
        pane?.start()
        client.request("initialize", [
            "protocolVersion": 1,
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false]],
        ]) { [weak self] result in
            guard case .success = result, let self else {
                self?.delegate?.sessionDidFail(self!, reason: "initialize 失败")
                return completion?(false)
            }
            self.client.request("session/new", [
                "cwd": self.cwd ?? NSNull(), "mcpServers": [],
            ]) { [weak self] result in
                guard let self, case .success(let value) = result,
                      let sessionId = value["sessionId"] as? String else {
                    self?.delegate?.sessionDidFail(self!, reason: "session/new 失败")
                    return completion?(false)
                }
                self.sessionId = sessionId
                self.emit([.ready])
                completion?(true)
            }
        }
    }

    private func handleFrame(kind: UInt8, data: Data) {
        guard kind == SessionOutputKind.output else { return } // SIZE/SNAPSHOT 已进 ring，无需解析
        client.feed([UInt8](data))
    }

    func send(_ text: String) {
        guard let sessionId, !isWorking else { return }
        isWorking = true
        client.request("session/prompt", [
            "sessionId": sessionId,
            "content": [["type": "text", "text": text]],
        ]) { [weak self] result in
            guard let self else { return }
            self.isWorking = false
            let stop = (try? result.get()["stopReason"] as? String) ?? nil
            self.emit([.turnEnded(stopReason: stop)])
        }
    }

    func cancel() {
        guard let sessionId else { return }
        client.notify("session/cancel", ["sessionId": sessionId])
    }

    func respondPermission(requestID: Int, optionId: String) {
        client.respond(id: requestID,
                       result: ["outcome": ["outcome": "selected", "optionId": optionId]])
    }

    func shutdown() {
        pane?.close()
        pane = nil
        sessionId = nil
        connected = false
    }

    // MARK: - Inbound interpretation (internal for agenttest)

    /// Route one decoded inbound JSON-RPC message into typed events.
    /// Kept off ACPClient so tests can drive it with fixtures.
    func interpret(_ message: [String: Any]) {
        guard message["method"] as? String == "session/update",
              let params = message["params"] as? [String: Any],
              let update = params["update"] as? [String: Any],
              let kind = update["sessionUpdate"] as? String else {
            if message["method"] as? String == "session/request_permission",
               let id = message["id"] as? Int,
               let params = message["params"] as? [String: Any] {
                let options = (params["options"] as? [[String: Any]] ?? []).compactMap(ACPOption.initDict)
                let title = (params["toolCall"] as? [String: Any])?["title"] as? String
                emit([.permissionRequested(
                    ACPPermissionPrompt(requestID: id, toolCallTitle: title, options: options))])
            }
            return
        }
        switch kind {
        case "agent_message_chunk":
            if let content = (update["content"] as? [String: Any]).flatMap(ACPContent.init),
               let text = content.text {
                emit([.messageChunk(text)])
            }
        case "agent_thought_chunk":
            if let content = (update["content"] as? [String: Any]).flatMap(ACPContent.init),
               let text = content.text {
                emit([.thoughtChunk(text)])
            }
        case "tool_call", "tool_call_update":
            guard let id = update["toolCallId"] as? String else { return }
            let content = ((update["content"] as? [[String: Any]]) ?? []).compactMap(ACPContent.init)
            emit([.toolCallUpdate(id: id,
                                  title: update["title"] as? String,
                                  kind: update["kind"] as? String,
                                  status: update["status"] as? String,
                                  content: content)])
        case "plan":
            let entries = ((update["entries"] as? [[String: Any]]) ?? []).compactMap(ACPPlanEntry.init)
            guard !entries.isEmpty else { return }
            emit([.plan(entries)])
        default:
            break
        }
    }

    private func emit(_ events: [AgentSessionEvent]) {
        delegate?.session(self, didEmit: events)
    }
}
```

`ACPOption.initDict` — 在 ACPTypes.swift 给两个 struct 加 `init?(_ raw: [String: Any])` 后，为满足上面 `compactMap(ACPOption.initDict)` 的写法，统一加：

```swift
extension ACPOption {
    initDict(_ raw: [String: Any]) -> ACPOption? { ACPOption(optionId: raw["optionId"] as? String ?? "",
                                                             name: raw["name"] as? String ?? "",
                                                             kind: raw["kind"] as? String) }
}
```

（若编译器对 `compactMap(initDict)` 成员查找挑剔，就地改写为闭包 `{ ACPOption($0) }`，给 ACPOption 也补 `init?(_ raw:)`。以编译通过、语义不变为准。）

注意：`try? result.get()["stopReason"]` 写法无效——`result.get()` 抛错语义混乱，直接：

```swift
            if case .success(let value) = result {
                self.emit([.turnEnded(stopReason: value["stopReason"] as? String)])
            } else {
                self.emit([.turnEnded(stopReason: nil)])
            }
```

- [ ] **Step 5: manifest 扩展（AgentManifests.swift 追加）**

```swift
// MARK: - ACP (Agent Client Protocol) launches

extension AgentManifests {
    /// One GUI agent session's spawn shape. V1: omp only — `omp acp` is
    /// native ACP; claude/codex/pi arrive via adapters in M3.
    struct ACPLaunch {
        let command: String
        let args: [String]
        /// Agent transcripts outgrow the 8 MiB default replay ring
        /// (spec: single tool results reach hundreds of KB).
        let ringBytes: UInt64
    }

    static func acpLaunch(for key: String) -> ACPLaunch? {
        guard key == "omp" else { return nil }
        return ACPLaunch(command: "omp", args: ["acp"],
                         ringBytes: 67_108_864)
    }

    /// Ordered entries for the "New Agent Session" submenu.
    static let acpPickerOrder: [(key: String, label: String)] = [("omp", "omp (GUI)")]
}
```

（`AgentManifests` 现有形态是 enum 还是 struct 由实现者查看文件头决定 extension 目标；若是 enum，`struct ACPLaunch` 嵌套在 extension enum 中同样合法。）

- [ ] **Step 6: 跑测试确认通过**

Run: `swift-app/run-tests.sh` — Expected: agenttest 全绿（events 断言、manifest 断言）。

- [ ] **Step 7: Commit**

```bash
git add swift-app/Sources/Core/Agent swift-app/Sources/Core/Agents/AgentManifests.swift swift-app/tools/agenttest.swift
git commit -m "feat(agent): ACP subset types + AgentSession state machine + omp acp manifest"
```

---

### Task 5: agent-web — Vite+React 转录应用 + build.sh 资产打包

**Files:**
- Create: `swift-app/agent-web/package.json`、`vite.config.ts`、`tsconfig.json`、`index.html`、`src/main.tsx`、`src/store.ts`、`src/App.tsx`、`src/styles.css`
- Modify: `swift-app/build.sh`（bundle 组装段，`cp Assets/AppIcon.icns` 附近，约 99 行后）

**Interfaces:**
- Consumes: Swift 推送的 JSON 事件（Task 6 定义 exact 形状）。
- Produces: `agent-web/dist/`（静态资产）；JS 全局 `window.__goty = { push(events), ready() }`；出站 `window.webkit.messageHandlers.goty.postMessage({type:"permission", optionId})` 与 `{type:"ready"}`。
- 事件形状（Swift → JS，字段名以此为准，Task 6 逐一构造）：
  - `{type:"userMessage", text}` — 本地回显用户输入
  - `{type:"agentChunk", text}` / `{type:"thoughtChunk", text}` — 追加到当前 agent/thought 段
  - `{type:"toolCall", id, title?, kind?, status?, content:[{type,text?,path?}]}` — upsert by id
  - `{type:"plan", entries:[{content,priority?,status?}]}` — 整体替换
  - `{type:"permission", requestID, toolCallTitle?, options:[{optionId,name,kind?}]}` — 当前待审批卡（一次一张）
  - `{type:"permissionResolved"}` — 移除审批卡
  - `{type:"turnEnded"}` — 结束当前段
  - `{type:"theme", vars:{"--goty-bg":..,"--goty-fg":..,"--goty-accent":..,"--goty-muted":..}}`

- [ ] **Step 1: 脚手架文件**

`package.json`：

```json
{
  "name": "goty-agent-web",
  "private": true,
  "version": "0.1.0",
  "type": "module",
  "scripts": { "build": "tsc --noEmit && vite build" },
  "dependencies": {
    "react": "^18.3.1",
    "react-dom": "^18.3.1",
    "react-markdown": "^9.0.1",
    "remark-gfm": "^4.0.0",
    "rehype-highlight": "^7.0.1",
    "highlight.js": "^11.10.0"
  },
  "devDependencies": {
    "@types/react": "^18.3.12",
    "@types/react-dom": "^18.3.1",
    "@vitejs/plugin-react": "^4.3.4",
    "typescript": "^5.6.3",
    "vite": "^5.4.11"
  }
}
```

`vite.config.ts`：

```ts
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  base: "./",
  build: { outDir: "dist", assetsInlineLimit: 0 },
});
```

`tsconfig.json`：

```json
{
  "compilerOptions": {
    "target": "ES2021", "lib": ["ES2021", "DOM"], "jsx": "react-jsx",
    "module": "ESNext", "moduleResolution": "bundler",
    "strict": true, "skipLibCheck": true, "noEmit": true
  },
  "include": ["src"]
}
```

`index.html`：

```html
<!doctype html>
<html>
  <head><meta charset="utf-8" /><script type="module" src="/src/main.tsx"></script></head>
  <body><div id="root"></div></body>
</html>
```

- [ ] **Step 2: store.ts（极简 pub/sub，无依赖）**

```ts
export type ToolContent = { type: string; text?: string; path?: string };
export type ToolCall = {
  id: string; title?: string; kind?: string; status?: string; content: ToolContent[];
};
export type PlanEntry = { content: string; priority?: string; status?: string };
export type Permission = {
  requestID: number; toolCallTitle?: string;
  options: { optionId: string; name: string; kind?: string }[];
};
export type Block =
  | { kind: "user"; text: string }
  | { kind: "agent"; text: string }
  | { kind: "thought"; text: string }
  | { kind: "tool"; call: ToolCall }
  | { kind: "plan"; entries: PlanEntry[] };

type Listener = () => void;

class Store {
  blocks: Block[] = [];
  toolOrder: string[] = [];
  tools = new Map<string, ToolCall>();
  permission: Permission | null = null;
  listeners = new Set<Listener>();

  subscribe(fn: Listener) { this.listeners.add(fn); return () => this.listeners.delete(fn); }
  private emit() { this.listeners.forEach((l) => l()); }

  apply(event: any) {
    switch (event.type) {
      case "userMessage": this.blocks.push({ kind: "user", text: event.text }); break;
      case "agentChunk":
        this.tail("agent").text += event.text; break;
      case "thoughtChunk":
        this.tail("thought").text += event.text; break;
      case "toolCall": {
        const call: ToolCall = { id: event.id, title: event.title, kind: event.kind,
                                 status: event.status, content: event.content ?? [] };
        if (!this.tools.has(event.id)) {
          this.toolOrder.push(event.id);
          this.blocks.push({ kind: "tool", call });
        }
        this.tools.set(event.id, call);
        break;
      }
      case "plan": this.blocks.push({ kind: "plan", entries: event.entries ?? [] }); break;
      case "permission": this.permission = event; break;
      case "permissionResolved": this.permission = null; break;
      case "turnEnded": this.blocks.push({ kind: "agent", text: "" }); break;
      default: return;
    }
    this.emit();
  }

  /// agent/thought chunks append to the LAST block of that kind; a closed
  /// turn (turnEnded/userMessage/tool in between) starts a fresh block.
  private tail(kind: "agent" | "thought"): { text: string } {
    const last = this.blocks[this.blocks.length - 1];
    if (last && last.kind === kind) return last;
    const block = { kind, text: "" } as Block;
    this.blocks.push(block);
    return block as { text: string };
  }
}

export const store = new Store();
```

（`tail` 的返回类型断言 `as Block` 与 `as { text: string }` 由实现者按 TS 严格模式微调，语义不变：同-kind 尾块追加，否则新开。）

- [ ] **Step 3: main.tsx + App.tsx + styles.css**

`src/main.tsx`：

```tsx
import React from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import { store } from "./store";
import "./styles.css";

declare global {
  interface Window {
    __goty: { push(events: unknown[]): void };
    webkit?: { messageHandlers: { goty: { postMessage(msg: unknown): void } } };
  }
}

let queued: unknown[] = [];
let flushScheduled = false;

window.__goty = {
  push(events: unknown[]) {
    queued.push(...events);
    if (flushScheduled) return;
    flushScheduled = true;
    requestAnimationFrame(() => {
      flushScheduled = false;
      for (const event of queued.splice(0)) store.apply(event);
    });
  },
};

const root = createRoot(document.getElementById("root")!);
root.render(<App />);
window.webkit?.messageHandlers.goty.postMessage({ type: "ready" });
```

`src/App.tsx`：

```tsx
import React, { useEffect, useRef, useSyncExternalStore } from "react";
import Markdown from "react-markdown";
import remarkGfm from "remark-gfm";
import rehypeHighlight from "rehype-highlight";
import { store } from "./store";

export function App() {
  const snapshot = useSyncExternalStore(
    (onChange) => store.subscribe(onChange),
    () => store.blocks.length + ":" + store.permission?.requestID,
  );
  const scroller = useRef<HTMLDivElement>(null);
  const pinned = useRef(true);

  useEffect(() => {
    if (pinned.current) scroller.current?.scrollTo(0, scroller.current.scrollHeight);
  }, [snapshot]);

  const onScroll = () => {
    const el = scroller.current!;
    pinned.current = el.scrollHeight - el.scrollTop - el.clientHeight < 40;
  };

  return (
    <div className="transcript" ref={scroller} onScroll={onScroll}>
      {store.blocks.map((block, i) => {
        switch (block.kind) {
          case "user": return <div key={i} className="user">{block.text}</div>;
          case "agent": return block.text ? (
            <div key={i} className="agent"><Markdown remarkPlugins={[remarkGfm]}
              rehypePlugins={[rehypeHighlight]}>{block.text}</Markdown></div>) : null;
          case "thought": return <div key={i} className="thought">{block.text}</div>;
          case "tool": {
            const call = store.tools.get(block.call.id)!;
            return (
              <details key={i} className={"tool " + (call.status ?? "")} open={call.status === "in_progress"}>
                <summary>{call.title ?? call.id}<span className="status">{call.status}</span></summary>
                {call.content.map((c, j) => c.text ? <pre key={j}><code>{c.text}</code></pre>
                  : c.path ? <div key={j} className="path">{c.path}</div> : null)}
              </details>
            );
          }
          case "plan": return (
            <ul key={i} className="plan">
              {block.entries.map((e, j) => (
                <li key={j} className={e.status}>{e.content}</li>))}
            </ul>
          );
        }
      })}
      {store.permission && (
        <div className="permission">
          <div className="title">{store.permission.toolCallTitle ?? "需要授权"}</div>
          <div className="options">
            {store.permission.options.map((o) => (
              <button key={o.optionId}
                onClick={() => window.webkit?.messageHandlers.goty.postMessage(
                  { type: "permission", optionId: o.optionId })}>
                {o.name}
              </button>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}
```

`src/styles.css`（变量由 Swift 的 theme 事件写入 `:root`）：

```css
:root { --goty-bg: #1c1c1c; --goty-fg: #ddeedd; --goty-accent: #4d4d4d; --goty-muted: #8a8a8a; }
* { box-sizing: border-box; }
html, body, #root { height: 100%; margin: 0; }
body { background: var(--goty-bg); color: var(--goty-fg);
  font: 13px/1.55 -apple-system, "SF Pro Text", "PingFang SC", sans-serif; }
.transcript { height: 100%; overflow-y: auto; padding: 12px 16px; }
.user { white-space: pre-wrap; margin: 10px 0; padding: 8px 12px;
  background: var(--goty-accent); border-radius: 8px; }
.agent { margin: 10px 0; }
.thought { color: var(--goty-muted); font-size: 12px; margin: 8px 0;
  border-left: 2px solid var(--goty-accent); padding-left: 10px; white-space: pre-wrap; }
.tool { margin: 6px 0; border: 1px solid var(--goty-accent); border-radius: 6px; }
.tool summary { cursor: pointer; padding: 5px 10px; list-style: none; }
.tool .status { float: right; color: var(--goty-muted); }
.tool pre { margin: 0; padding: 6px 10px; overflow-x: auto;
  border-top: 1px solid var(--goty-accent); }
.tool .path { padding: 4px 10px; color: var(--goty-muted); }
.plan { list-style: none; padding-left: 6px; margin: 8px 0; }
.plan li::before { content: "○ "; }
.plan li.completed::before { content: "● "; }
.plan li.in_progress::before { content: "◐ "; }
.permission { position: sticky; bottom: 8px; margin-top: 12px; padding: 10px 12px;
  background: var(--goty-accent); border-radius: 8px; }
.permission .options { display: flex; gap: 8px; margin-top: 8px; }
.permission button { background: var(--goty-bg); color: var(--goty-fg);
  border: 1px solid var(--goty-muted); border-radius: 6px; padding: 4px 14px; }
code { font-family: "SF Mono", Menlo, monospace; font-size: 12px; }
pre { background: color-mix(in srgb, var(--goty-bg) 80%, white 6%); border-radius: 6px; }
```

- [ ] **Step 4: 安装依赖并构建**

Run: `cd swift-app/agent-web && npm install && npm run build`
Expected: `dist/` 产出，`tsc --noEmit` 无错误。

- [ ] **Step 5: build.sh 打包（`cp Assets/AppIcon.icns ...` 行之后插入）**

```bash
# Agent transcript web app: built by npm at packaging time only; the
# bundle ships the static dist (no network at runtime).
if [ -d agent-web/node_modules ] || command -v npm >/dev/null 2>&1; then
    ( cd agent-web && npm install --no-fund --no-audit && npm run build )
    mkdir -p "$APP/Contents/Resources/agent-web"
    cp -R agent-web/dist/ "$APP/Contents/Resources/agent-web/"
else
    echo "agent-web: npm not found — Agent GUI sessions will not render" >&2
    exit 1
fi
```

- [ ] **Step 6: 验证 + Commit**

Run: `swift-app/build.sh`
Expected: 构建成功，`Goty.app/Contents/Resources/agent-web/index.html` 存在。

```bash
git add swift-app/agent-web swift-app/build.sh
git commit -m "feat(agent-web): react transcript app (markdown, tool cards, permission card) + bundle packaging"
```

（`agent-web/node_modules`、`dist` 需要进 `.gitignore`——提交前确认根 `.gitignore` 追加两行 `swift-app/agent-web/node_modules/`、`swift-app/agent-web/dist/`。）

---

### Task 6: UI — PaneHosting 协议 + PaneState.kind + AgentPaneHost

**Files:**
- Modify: `swift-app/Sources/Core/Workspace/Models.swift`（PaneState.kind）
- Modify: `swift-app/Sources/UI/Terminal/TerminalViews.swift`（PaneHosting 协议、PaneGridView 项类型）
- Create: `swift-app/Sources/UI/Agent/AgentPaneHost.swift`
- Create: `swift-app/Sources/UI/Agent/AgentWebBridge.swift`
- Modify: `swift-app/Sources/App/AppDelegate.swift`（makePaneHost 分支、hostPool 类型）

**Interfaces:**
- Consumes: `AgentSession`（Task 4）、`AgentManifests.ACPLaunch`。
- Produces:
  - `enum PaneKind: Codable, Equatable { case terminal; case agent(String) }`；`PaneState.kind: PaneKind`（旧 state.json 解码为 `.terminal`）。
  - `protocol PaneHosting: AnyObject { var hostKey: HostKey { get }; var view: NSView { get }; func setVisible(_ visible: Bool); func syncCoreVisibility(); func retire() }`；`extension PaneHost: PaneHosting`（`view` 返回 self；`setVisible` 映射现有 isHidden 逻辑——实现者对照 PaneGridView.setVisiblePanes 现有调用面收敛方法名）。
  - `final class AgentPaneHost: NSView, PaneHosting`：`init(key: HostKey, workspace: WorkspaceState, makeSession: @escaping (String) -> AgentSession?)`（参数为 pane runtime id）；`var onWorkingChange: ((Bool) -> Void)?`；`var onPermissionPending: ((Bool) -> Void)?`。
  - `AgentWebBridge`：Swift↔JS 双向桥 + 主题推送。
  - AppDelegate `hostPool: [HostKey: any PaneHosting]`；`makePaneHost` 返回 `any PaneHosting`。

- [ ] **Step 1: PaneState.kind（含向后兼容解码）**

Models.swift 中 `struct PaneState: Codable` 改为：

```swift
enum PaneKind: Codable, Equatable {
    case terminal
    /// A GUI agent session; payload = the AgentCatalog key ("omp").
    case agent(String)
}

struct PaneState: Codable {
    let id: String        // pane UUID (stable, persisted)
    var cwd: String?
    var left: Int = 0
    var top: Int = 0
    var width: Int = 1
    var height: Int = 1
    /// Terminal pane vs GUI agent session. Absent in older state.json —
    /// decodes as .terminal so no migration is ever needed.
    var kind: PaneKind = .terminal

    init(id: String, cwd: String?, kind: PaneKind = .terminal) {
        self.id = id
        self.cwd = cwd
        self.kind = kind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        left = try container.decodeIfPresent(Int.self, forKey: .left) ?? 0
        top = try container.decodeIfPresent(Int.self, forKey: .top) ?? 0
        width = try container.decodeIfPresent(Int.self, forKey: .width) ?? 1
        height = try container.decodeIfPresent(Int.self, forKey: .height) ?? 1
        kind = try container.decodeIfPresent(PaneKind.self, forKey: .kind) ?? .terminal
    }
}
```

（CodingKeys 保留编译器合成即可——自定义 `init(from:)` 不阻止合成 `encode(to:)` 与 CodingKeys。）

- [ ] **Step 2: PaneHosting 协议 + PaneHost 适配 + PaneGridView 泛化**

TerminalViews.swift 顶部（PaneDaemonTarget 旁）：

```swift
/// One grid-hostable pane view: the terminal surface (PaneHost) or a GUI
/// agent session (AgentPaneHost). PaneGridView and the AppDelegate host
/// pool hold these indifferently.
protocol PaneHosting: AnyObject {
    var hostKey: HostKey { get }
    var view: NSView { get }
    func setVisible(_ visible: Bool)
    func syncCoreVisibility()
    func retire()
}
```

给 `PaneHost` 补 conform（方法映射到现有成员——实现者打开 PaneHost 类体找到对应可见性/退役成员后写 extension；若成员名不同，以现有名为准、协议方法做转发）：

```swift
extension PaneHost: PaneHosting {
    var view: NSView { self }
    func setVisible(_ visible: Bool) { isHidden = !visible }
}
```

`PaneGridView.Item` 的 `host: PaneHost` 改 `host: any PaneHosting`；`setVisiblePanes` 与 `keepAlive` 参数类型 `[PaneHost]` → `[any PaneHosting]`；方法体内 `item.host.syncCoreVisibility()` 等调用不变。

- [ ] **Step 3: AgentWebBridge.swift**

```swift
// goty — see CLAUDE.md for the working principles.
import AppKit
import WebKit

/// Swift → JS event pump + JS → Swift message sink for one agent pane.
/// Events are coalesced per runloop turn (requestAnimationFrame on the
/// JS side batches paint; here we batch the evaluateJavaScript calls).
final class AgentWebBridge: NSObject, WKScriptMessageHandler {
    private weak var webView: WKWebView?
    private var queue: [[String: Any]] = []
    private var flushScheduled = false
    private var jsReady = false
    /// Composer 审批按钮 → AgentPaneHost
    var onPermissionOption: ((String) -> Void)?

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
        webView.configuration.userContentController.add(self, name: "goty")
    }

    func push(_ event: [String: Any]) {
        queue.append(event)
        scheduleFlush()
    }

    func pushTheme() {
        let theme = Chrome.theme
        func hex(_ color: NSColor) -> String {
            let c = color.usingColorSpace(.sRGB) ?? color
            return String(format: "#%02x%02x%02x",
                          Int(round(c.redComponent * 255)),
                          Int(round(c.greenComponent * 255)),
                          Int(round(c.blueComponent * 255)))
        }
        push(["type": "theme", "vars": [
            "--goty-bg": hex(theme.background),
            "--goty-fg": hex(theme.legibleForeground()),
            "--goty-accent": hex(theme.accent),
            "--goty-muted": hex(theme.accent),
        ]])
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            guard self.jsReady, !self.queue.isEmpty, let webView = self.webView else { return }
            let batch = self.queue
            self.queue = []
            guard let data = try? JSONSerialization.data(withJSONObject: batch),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("window.__goty.push(\(json))", completionHandler: nil)
        }
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        switch body["type"] as? String {
        case "ready":
            jsReady = true
            pushTheme()          // ready 后先补主题，再 flush 积压事件
            scheduleFlush()
        case "permission":
            if let optionId = body["optionId"] as? String {
                onPermissionOption?(optionId)
                push(["type": "permissionResolved"])
            }
        default:
            break
        }
    }
}
```

- [ ] **Step 4: AgentPaneHost.swift**

```swift
// goty — see CLAUDE.md for the working principles.
import AppKit
import WebKit

/// One GUI agent session pane: WKWebView transcript + native composer.
/// The webview is a disposable view of AgentSession state — the process
/// and its transcript live in sessiond (ring) / the agent (session file).
final class AgentPaneHost: NSView, PaneHosting, WKUIDelegate, AgentSessionDelegate {
    let hostKey: HostKey
    var view: NSView { self }

    /// Sidebar 状态接线（Task 7 由 AppDelegate 桥到 coordinator）
    var onWorkingChange: ((Bool) -> Void)?
    var onPermissionPending: ((Bool) -> Void)?

    private let session: AgentSession
    private let webView: WKWebView
    private let bridge: AgentWebBridge
    private let composer = ComposerView()
    private let statusLabel = NSTextField(labelWithString: "连接中…")

    init(key: HostKey, session: AgentSession) {
        self.hostKey = key
        self.session = session

        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        bridge = AgentWebBridge(webView: webView)

        super.init(frame: .zero)
        wantsLayer = true

        webView.translatesAutoresizingMaskIntoConstraints = false
        composer.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        addSubview(statusLabel)
        addSubview(composer)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: webView.bottomAnchor, constant: 4),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            composer.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            composer.leadingAnchor.constraint(equalTo: leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: bottomAnchor),
            composer.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])

        session.delegate = self
        bridge.onPermissionOption = { [weak self] optionId in
            guard let self, let prompt = self.pendingPrompt else { return }
            self.session.respondPermission(requestID: prompt.requestID, optionId: optionId)
            self.pendingPrompt = nil
            self.onPermissionPending?(false)
        }
        composer.onSend = { [weak self] text in
            guard let self else { return }
            self.bridge.push(["type": "userMessage", "text": text])
            self.session.send(text)
        }
        composer.onStop = { [weak self] in self?.session.cancel() }

        loadWebApp()
        session.connect { [weak self] ok in
            self?.statusLabel.stringValue = ok ? "就绪" : "连接失败"
        }
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    private var pendingPrompt: ACPPermissionPrompt?

    private func loadWebApp() {
        let dir = Self.webAppDirectory()
        let index = dir.appendingPathComponent("index.html")
        webView.loadFileURL(index, allowingReadAccessTo: dir)
    }

    /// Packaged bundle first; repo fallback for run-tests/dev tools.
    static func webAppDirectory() -> URL {
        if let bundled = Bundle.main.url(forResource: "index", withExtension: "html",
                                         subdirectory: "agent-web") {
            return bundled.deletingLastPathComponent()
        }
        let repo = URL(fileURLWithPath: #filePath) // Sources/UI/Agent/AgentPaneHost.swift
            .deletingLastPathComponent().deletingLastPathComponent() // UI
            .deletingLastPathComponent().deletingLastPathComponent() // Sources
            .deletingLastPathComponent().deletingLastPathComponent() // swift-app
        return repo.appendingPathComponent("agent-web/dist")
    }

    // MARK: PaneHosting

    func setVisible(_ visible: Bool) { isHidden = !visible }
    func syncCoreVisibility() {} // webview 自管生命周期，无需 occlusion 联动
    func retire() {
        session.shutdown()
        webView.stopLoading()
    }

    // MARK: AgentSessionDelegate（Core 回调，切主线程再碰 UI）

    func session(_ session: AgentSession, didEmit events: [AgentSessionEvent]) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var js: [[String: Any]] = []
            for event in events {
                switch event {
                case .ready:
                    self.statusLabel.stringValue = "就绪"
                case .messageChunk(let text):
                    js.append(["type": "agentChunk", "text": text])
                case .thoughtChunk(let text):
                    js.append(["type": "thoughtChunk", "text": text])
                case .toolCallUpdate(let id, let title, let kind, let status, let content):
                    js.append(["type": "toolCall", "id": id, "title": title ?? NSNull(),
                               "kind": kind ?? NSNull(), "status": status ?? NSNull(),
                               "content": content.map { ["type": $0.type,
                                                         "text": $0.text ?? NSNull(),
                                                         "path": $0.path ?? NSNull()] }])
                case .plan(let entries):
                    js.append(["type": "plan", "entries": entries.map { [
                        "content": $0.content,
                        "priority": $0.priority ?? NSNull(),
                        "status": $0.status ?? NSNull()] }])
                case .permissionRequested(let prompt):
                    self.pendingPrompt = prompt
                    self.onPermissionPending?(true)
                    js.append(["type": "permission", "requestID": prompt.requestID,
                               "toolCallTitle": prompt.toolCallTitle ?? NSNull(),
                               "options": prompt.options.map { ["optionId": $0.optionId,
                                                                "name": $0.name,
                                                                "kind": $0.kind ?? NSNull()] }])
                case .turnEnded:
                    js.append(["type": "turnEnded"])
                }
            }
            for event in js { self.bridge.push(event) }
        }
    }

    func sessionDidFail(_ session: AgentSession, reason: String) {
        DispatchQueue.main.async { [weak self] in
            self?.statusLabel.stringValue = reason
        }
    }
}
```

`ComposerView`（同文件底部，原生输入条；IME 安全：`hasMarkedText` 时不发送）：

```swift
/// One-line native composer: Enter sends, Shift+Enter newlines, ⌘↵ always
/// sends. NSTextView keeps Chinese IME composition exactly like the rest
/// of the app (webview textarea IME is the failure mode we avoid).
final class ComposerView: NSView, NSTextViewDelegate {
    var onSend: ((String) -> Void)?
    var onStop: (() -> Void)?

    private let textView = NSTextView()
    private let sendButton = NSButton(title: "发送", target: nil, action: nil)
    private let stopButton = NSButton(title: "停止", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for button in [sendButton, stopButton] {
            button.bezelStyle = .rounded
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
        }
        sendButton.target = self; sendButton.action = #selector(didSend)
        stopButton.target = self; stopButton.action = #selector(didStop)

        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        textView.delegate = self
        textView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            textView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            sendButton.leadingAnchor.constraint(equalTo: textView.trailingAnchor, constant: 8),
            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            sendButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            stopButton.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -6),
            stopButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        window?.makeFirstResponder(textView)
        return ok
    }

    @objc private func didSend() {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        textView.string = ""
        onSend?(text)
    }

    @objc private func didStop() { onStop?() }
}
```

（Enter 发送：NSTextView 默认 Enter 换行。M1 用「⌘↵ / 发送按钮」——`doCommandBySelector:` 里拦截 `insertNewline:` + `commandModifier` 需要子类化 NSTextView，M1 从简：**发送按钮 + ⌘↵ 不做**，输入体验打磨列 M2；此决定记录在此，避免实现者自行加码。若要 Enter 发送：子类 NSTextView 覆写 `keyDown` 判断 `(modifierFlags & [.shift, .command]).isEmpty && !hasMarkedText` 时调 onSend——可选实现，二选一。）

- [ ] **Step 5: makePaneHost 分支 + hostPool 泛化**

AppDelegate.swift：`hostPool` 类型 `[HostKey: PaneHost]` → `[HostKey: any PaneHosting]`。`makePaneHost` 改：

```swift
    func makePaneHost(pane: PaneState, ws: WorkspaceState,
                      gapp: ghostty_app_t) -> (any PaneHosting)? {
        let key = HostKey(workspace: ws.id, pane: pane.id)
        if let existing = hostPool[key] { return existing }
        if case .agent(let agentKey) = pane.kind {
            return makeAgentPaneHost(pane: pane, ws: ws, key: key, agentKey: agentKey)
        }
        // ……现有 PaneHost 构造路径保持不变，返回类型随协议改为 any PaneHosting
    }
```

（`makeAgentPaneHost` 与 daemon target 在 Task 7 补全；本 Task 先让协议化编译通过：临时实现 `makeAgentPaneHost` 里用 `paneDaemonTarget` 相同的 environment 构造 `AgentSession(paneId: key.runtimeId, ..., daemon: daemonFor?(ws) ?? .shared, launch: AgentManifests.acpLaunch(for: agentKey)!)` 并 `AgentPaneHost(key: session:)`。launch 为 nil 时返回 nil。）

- [ ] **Step 6: 跑测试 + commit**

Run: `swift-app/run-tests.sh`（现有四组不得回归）与 `swift-app/build.sh` 编译通过。

```bash
git add swift-app/Sources swift-app/Sources/App
git commit -m "feat(ui): PaneHosting protocol + AgentPaneHost (WKWebView transcript, native composer, theme push)"
```

---

### Task 7: 接线 — 菜单入口、coordinator、sidebar 状态、EXITED 处理

**Files:**
- Modify: `swift-app/Sources/Core/Workspace/WorkspaceCoordinator.swift`
- Modify: `swift-app/Sources/App/AppDelegate.swift`（makeAgentPaneHost、daemon target）
- Modify: `swift-app/Sources/App/AppDelegate+Menu.swift`

**Interfaces:**
- Consumes: Task 4 `AgentManifests.acpPickerOrder`、Task 2 `SessionDaemon.supportsAgentSessions()`、Task 6 全部。
- Produces: `WorkspaceCoordinator.newAgentSessionTab(agent: String = "omp")`；菜单项「New Agent Session ▸ omp (GUI)」。

- [ ] **Step 1: coordinator 新入口（appendTab 加 kind）**

```swift
    /// New GUI agent session (M1: omp, local daemon only). The caller
    /// gates on SessionDaemon.supportsAgentSessions().
    func newAgentSessionTab(agent: String = "omp") {
        appendTab(name: agent, command: agent, cwd: activeCwd(), kind: .agent(agent))
    }
```

`appendTab(name:command:cwd:)` 追加 `kind: PaneKind = .terminal` 参数，`PaneState(id:cwd:)` 构造传 `kind`；`newAgentTab/newTab/newTab(cwd:)` 不变（默认 .terminal）。

- [ ] **Step 2: 菜单（AppDelegate+Menu.swift，"New Agent Space" 之后）**

```swift
        let sessionMenu = NSMenu()
        for (key, label) in AgentManifests.acpPickerOrder {
            let item = NSMenuItem(title: label,
                                  action: #selector(menuNewAgentSessionFrom(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = key
            sessionMenu.addItem(item)
        }
        let sessionItem = NSMenuItem(title: "New Agent Session", action: nil, keyEquivalent: "")
        sessionItem.submenu = sessionMenu
        shellMenu.addItem(sessionItem)
```

```swift
    @objc private func menuNewAgentSessionFrom(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        guard SessionDaemon.supportsAgentSessions() else {
            let alert = NSAlert()
            alert.messageText = "Agent GUI Session 需要 newer sessiond"
            alert.informativeText = "本机 sessiond 版本过旧（CAPABILITY < 4）。重启 Goty 会自动换用随包 sessiond；SSH 远程主机需更新其 goty-sessiond。"
            alert.runModal()
            return
        }
        coordinator.newAgentSessionTab(agent: key)
    }
```

- [ ] **Step 3: daemon target（AppDelegate）**

`paneDaemonTarget(wsId:command:)` 旁加 agent 变体（environment 走 UserShellEnv，PATH 里找 omp）：

```swift
    /// Agent session spawn shape: the ACP command via the user's real
    /// login environment (version managers), no ghostty surface.
    func agentPaneTarget(wsId: UUID, launch: AgentManifests.ACPLaunch) -> PaneDaemonTarget? {
        guard let ws = coordinator.store?.workspaces.first(where: { $0.id == wsId }) else { return nil }
        return PaneDaemonTarget(
            daemon: daemonRouter(ws),
            shell: launch.command,
            args: launch.args,
            environment: UserShellEnv.asDictionary)
    }
```

（`daemonRouter` = 现有 `daemonFor` 注入的同一闭包/本地回退，实现者对照 `paneDaemonTarget` 现体内取 daemon 的写法照抄。）
`makeAgentPaneHost` 用它构造 `AgentSession(paneId: key.runtimeId, cwd: pane.cwd, grid: .fixedGrid, environment: target.environment, launch: launch, daemon: target.daemon, delegate: nil)`，再 `AgentPaneHost(key: session:)`，并把 `host.onWorkingChange` 桥到 `coordinator.agentStateUpdated(wsId:paneId:state:)`（`true → .working`，`false → .idle`；`onPermissionPending → .blocked`）。

- [ ] **Step 4: 手动冒烟**

```bash
swift-app/build.sh && swift-app/restart-app.sh
```

验收清单（对照 spec M1）：
1. 菜单 New Agent Session ▸ omp (GUI) → 新 space，状态「就绪」。
2. 输入「列出 src 下文件并读其中一个」→ 转录流式出现 markdown；工具调用卡片展开/收起正常。
3. 触发一个需要审批的操作 → 审批卡出现 → 点 Allow → agent 继续。
4. 「停止」可打断当前 turn。
5. 关闭整个 GUI（窗口关掉，daemon 常驻）→ 重开 Goty → 同一 space 转录完整重建（ring 重放），agent 仍可继续对话。
6. 旧 state.json 兼容：升级前已有 terminal spaces 重启后原样恢复。
7. run-tests.sh / cargo 三连 / build.sh 全绿。

- [ ] **Step 5: Commit**

```bash
git add swift-app/Sources/App swift-app/Sources/Core/Workspace/WorkspaceCoordinator.swift
git commit -m "feat(agent): New Agent Session menu, coordinator wiring, sidebar status from ACP events"
```

---

### Task 8: 收尾 — 检查全绿 + 文档

**Files:**
- Modify: `swift-app/README`（或 README 安装节）：部署前提一行
- Modify: `.gitignore`（若 Task 5 未加）

- [ ] **Step 1: 全量检查**

```bash
cargo fmt --manifest-path swift-app/sessiond/Cargo.toml -- --check
cargo clippy --manifest-path swift-app/sessiond/Cargo.toml --all-targets -- -D warnings
cargo test --manifest-path swift-app/sessiond/Cargo.toml
swift-app/run-tests.sh
swift-app/build.sh
```
Expected: 全部通过，无新 warning。

- [ ] **Step 2: README 部署前提**

安装节追加：`Agent GUI Session（M1）要求目标机器 PATH 中有 omp ≥ 18.0.8（ACP 模式）；远程 SSH 主机同理，且其 goty-sessiond 需为 CAPABILITY 4 版本。`

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "docs(agent): deployment prerequisites for GUI agent sessions (M1)"
```

---

## Self-Review（已执行）

1. **Spec 覆盖（M1 行）**：sessiond no_echo/ring_bytes/CAPABILITY 4 → Task 1；Core/Agent ACP 子集 → Task 3/4；AgentPaneHost+agent-web → Task 5/6；「New Agent Session」菜单 → Task 7；发送/流式/审批/停止 → Task 4/6；detach→reattach → Task 7 冒烟第 5 条（openPane attach-first + ring 重放为既有行为，无需新代码）。M2/M3（session/load、SSH agent、模型切换、plan 卡 UI 之外项、其他 agent）不在本计划。
2. **占位符扫描**：无 TBD/「适当处理」。两处标注了实现自由度（Protocol conform 的现有成员名、compactMap 闭包写法），均给了判定标准（以编译与语义不变为准），不属于未定义行为。
3. **类型一致性**：`ACPLaunch(command:args:ringBytes:)`、`AgentPaneHost(key:session:)`、`SessionOpenPane noEcho/ringBytes` 参数名、JS 事件字段（Task 5 Interfaces 与 Task 6 构造逐一对应）、`pane_id` 复用 `HostKey.runtimeId` 均已对齐。

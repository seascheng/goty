# Agent 能力对齐（Capability Parity）实施计划 · Phase 1

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **STATUS: Phase 1 COMPLETE (2026-09-11)** — d9f6813 / d590aac / e808285 / 1df2bff / 5d05ac0；run-tests.sh 全绿、build.sh 无新警告、web 冒烟通过（chip 渲染 + setConfig(runtimeMode) 上桥）。执行方式：subagent 链路 provider 故障，退化内联执行。

**Architecture:** 在现有 `AgentConfigOption` 管线上加一个 `runtimeMode` 选项（configChanged 下发、setConfigOption 回传），不改 bridge 协议；Core 层新增纯映射函数（RuntimeMode → 各家原生参数），adapter 各自落地（codex: per-turn params；claude: 控制请求 + spawn 参数）。**不碰 omp/pi**（其审批是扩展对话框体系，无 launch 档位语义；等确认 omp CLI 档位 flag 后另开任务）。

**Tech Stack:** Swift（swift-app/Sources/Core + agent-web React/TS）；测试走 `tools/agenttest.swift`（真实 adapter 行为）+ agent-web `npm run build`。

**Spec:** 本文档即 spec（调研结论内嵌于「参考映射」表）。

## 参考映射（每个决策的出处）

| 决策 | 参照产品 | 证据 |
|---|---|---|
| 4 档 RuntimeMode 归一 | monocode | `src/lib/session.ts:123` `supervised/auto-accept-edits/auto/full-access` |
| mode → codex approvalPolicy+sandbox 每 turn 重发 | monocode | `src/lib/harness/codexProtocol.ts:20,101`（turn/start 带全套，无 mid-session API 依赖） |
| claude mid-session 切模式 | paseo | `providers/claude/agent.ts:2403` `setPermissionMode()`（SDK 控制协议 = 我们 `channel.send(control_request)` 同路） |
| claude bypass 需 spawn flag | monocode | `claudeProtocol.ts:247` `--allow-dangerously-skip-permissions` |
| mode 走 config 选项管线、UI 泛化 chip | monocode + 现有 goty | `ModelSettings.tsx` 目录驱动；goty `App.tsx:1441` ConfigChip 已泛化 |
| manifest 一致性测试 | happier | `connectedServiceSwitchContinuityCapabilityInvariant.test.ts`（声明与实现不符即挂） |

## 档位定义（唯一权威，写进 `AgentRuntimeMode` doc comment）

| goty 档 | 语义 | codex (approvalPolicy/sandbox/approvalsReviewer) | claude (permission-mode) |
|---|---|---|---|
| `supervised` | 命令和改动都先问 | `untrusted` / `read-only` / `user` | `default` |
| `autoEdits` | 自动批准编辑，其余先问 | `on-request` / `workspace-write` / `user` | `acceptEdits` |
| `auto` | 审批器自动过常规，危险仍问 | `on-request` / `workspace-write` / `auto_review` | `auto` |
| `fullAccess` | 全放行 | `never` / `danger-full-access` / `user` | `bypassPermissions` |

## Global Constraints

- 遵循 `AGENTS.md`：提交前 `cargo fmt/clippy/test`（sessiond 无改动则跳过）、`swift-app/run-tests.sh` 全绿、`swift-app/build.sh` 成功、新 Swift 警告视为错误。
- 逻辑进 `Sources/Core`（零 AppKit import）；UI 只进 `agent-web/src`。
- 开工前工作树必须干净（先提交/搁置现有未提交改动——里面有用户并发编辑的 `Models.swift`，**不得**一并提交进本计划的任务提交）。
- 中止/降级路径不许静默 no-op：adapter 不支持的档位操作要 `.notice()` 告知用户。
- 本计划**不改** sessiond Rust 侧。

## File Structure

- Modify: `swift-app/Sources/Core/Agent/AgentTypes.swift` — 新增 `AgentRuntimeMode` enum + `AgentPermissionTier` 语义注释。
- Create: `swift-app/Sources/Core/Agent/RuntimeModeMapping.swift` — 纯映射：goty 档位 → codex params dict / claude mode 字符串 + spawn flag。零依赖，可单测。
- Modify: `swift-app/Sources/Core/Agent/Adapters/CodexSession.swift` — 档位状态、configChanged 下发、turn/start & thread/start 参数注入。
- Modify: `swift-app/Sources/Core/Agent/Adapters/ClaudeSession.swift` — 档位状态、spawn 参数（`shellCommand`/`argv`）、mid-session 控制请求、init system 帧 `permissionMode` 回读。
- Modify: `swift-app/agent-web/src/App.tsx` — KNOWN_ORDER 注册 `runtimeMode` + 图标映射（shield）。
- Modify: `swift-app/tools/agenttest.swift` — 新增映射/行为断言。
- Test: 同 `agenttest.swift`（repo 惯例：Swift 逻辑测试都收在这里跑，`run-tests.sh` 驱动）。

---

### Task 1: `AgentRuntimeMode` + 纯映射层

**Files:**
- Create: `swift-app/Sources/Core/Agent/RuntimeModeMapping.swift`
- Modify: `swift-app/Sources/Core/Agent/AgentTypes.swift`（enum 放这里，映射放新文件）
- Test: `swift-app/tools/agenttest.swift`

**Interfaces:**
- Produces:
  - `enum AgentRuntimeMode: String, CaseIterable { case supervised, autoEdits, auto, fullAccess }`
  - `extension AgentRuntimeMode { var displayName: String; var hint: String }`
  - `enum RuntimeModeMapping { static func codexParams(_ m: AgentRuntimeMode) -> [String: Any]; static func codexThreadParams(_ m: AgentRuntimeMode) -> [String: Any]; static var claudeMode: (mode: String, spawnArgs: [String]) }` → 实为 `static func claudeSpawn(_ m: AgentRuntimeMode) -> (mode: String, extraArgs: [String])`

- [ ] **Step 1: 写失败测试**（agenttest.swift 末尾追加）

```swift
// runtimeMode mapping parity (monocode codexProtocol.ts:20 / claudeProtocol.ts:244)
func testRuntimeModeMapping() {
    checkEqual(RuntimeModeMapping.codexParams(.supervised)["approvalPolicy"] as? String, "untrusted")
    checkEqual(RuntimeModeMapping.codexParams(.autoEdits)["approvalPolicy"] as? String, "on-request")
    checkEqual(RuntimeModeMapping.codexParams(.auto)["approvalsReviewer"] as? String, "auto_review")
    checkEqual(RuntimeModeMapping.codexParams(.fullAccess)["approvalPolicy"] as? String, "never")
    checkEqual(RuntimeModeMapping.claudeSpawn(.supervised).mode, "default")
    checkEqual(RuntimeModeMapping.claudeSpawn(.fullAccess).mode, "bypassPermissions")
    check(RuntimeModeMapping.claudeSpawn(.fullAccess).extraArgs.contains("--allow-dangerously-skip-permissions"))
    check(RuntimeModeMapping.claudeSpawn(.autoEdits).extraArgs.isEmpty)
}
```

（`check`/`checkEqual` 用 agenttest 现有断言助手名——动手前先看文件里已有的写法，保持一致。）

- [ ] **Step 2: 跑 `run-tests.sh` 确认编译失败**（类型不存在）
- [ ] **Step 3: 实现类型与映射**（数值照抄上方档位表；`codexParams` 返回 `["approvalPolicy": String, "approvalsReviewer": String, "sandboxPolicy": ["type": "readOnly"|"workspaceWrite"|"dangerFullAccess"]]`；`codexThreadParams` 额外带 `"sandbox": String`——thread/start 用字符串沙箱、turn/start 用对象沙箱Policy，两形状都来自 monocode 原文）
- [ ] **Step 4: `run-tests.sh` 全绿**
- [ ] **Step 5: Commit** `feat(agent): runtime-mode enum + per-backend mapping (monocode parity)`

### Task 2: codex adapter 档位落地（per-turn 重发）

**Files:**
- Modify: `swift-app/Sources/Core/Agent/Adapters/CodexSession.swift`
- Test: `swift-app/tools/agenttest.swift`

**Interfaces:**
- Consumes: Task 1 的 `RuntimeModeMapping.codexParams/codexThreadParams`。
- Produces: adapter 行为——`configOptions` 含 `AgentConfigOption(id:"runtimeMode", name:"权限", category:"权限", currentValue:"supervised", options:[4 档])`；`setConfigOption(id:"runtimeMode", value:)` 存 `selectedRuntimeMode` 并回发 configChanged。

- [ ] **Step 1: 写失败测试**：agenttest 里用假的 turn/start 捕获（若 CodexSession 无注入点，把参数拼装抽成 `static func turnParams(threadId:text:model:images:) -> [String:Any]` 纯函数再测——**采用这个方案**，与现有 `stageImage` 同风格）:

```swift
func testCodexTurnParamsCarryRuntimeMode() {
    let p = CodexSession.turnParams(threadId: "t", text: "hi", model: nil, mode: .auto)
    checkEqual(p["approvalPolicy"] as? String, "on-request")
    checkEqual((p["sandboxPolicy"] as? [String: Any])?["type"] as? String, "workspaceWrite")
    checkEqual(p["approvalsReviewer"] as? String, "auto_review")
}
```

- [ ] **Step 2: 确认失败 → Step 3: 实现**：
  - `private var runtimeMode: AgentRuntimeMode = .supervised`
  - `send()` 的 `turnParams` 合并 `RuntimeModeMapping.codexParams(runtimeMode)`（`thread/start` 处即 `connect()` 内新建线程的调用点同样合并 `codexThreadParams`）。
  - `configOptions` 计算属性加 runtimeMode 项；`setConfigOption` 加 `case id == "runtimeMode"` 分支（`AgentRuntimeMode(rawValue: value)`，非法值 `.notice`）。
- [ ] **Step 4: `run-tests.sh` 全绿；`build.sh` 无新警告**
- [ ] **Step 5: Commit** `feat(codex): approval policy + sandbox ride every turn/start`

### Task 3: claude adapter 档位落地（mid-session 控制请求）

**Files:**
- Modify: `swift-app/Sources/Core/Agent/Adapters/ClaudeSession.swift`
- Test: `swift-app/tools/agenttest.swift`

**Interfaces:**
- Consumes: Task 1 的 `RuntimeModeMapping.claudeSpawn`。
- Produces: 同 Task 2 的 configOption 契约；`shellCommand(model:resume:)` 增 `mode:` 参数（带默认值，不动现有调用点签名兼容——实际改为 `shellCommand(model:resume:mode:)`，调用点同步更新，不留旧签名）。

- [ ] **Step 1: 写失败测试**（两段）:

```swift
func testClaudeSpawnArgsCarryPermissionMode() {
    let (_, args) = ClaudeSession.shellCommand(model: nil, resume: nil, mode: .autoEdits)
    check(args[0].contains("--permission-mode acceptEdits"))
    let (_, bypass) = ClaudeSession.shellCommand(model: nil, resume: nil, mode: .fullAccess)
    check(bypass[0].contains("--permission-mode bypassPermissions"))
    check(bypass[0].contains("--allow-dangerously-skip-permissions"))
}

func testClaudeModeSwitchControlFrame() {
    let frame = ClaudeSession.setPermissionModeFrame(.auto)
    checkEqual(frame["type"] as? String, "control_request")
    checkEqual((frame["request"] as? [String: Any])?["subtype"] as? String, "set_permission_mode")
    checkEqual((frame["request"] as? [String: Any])?["mode"] as? String, "auto")
}
```

- [ ] **Step 2: 确认失败 → Step 3: 实现**：
  - `static func setPermissionModeFrame(_ m: AgentRuntimeMode) -> [String: Any]`（`channel.send` 同 `cancel()` 的形状，request_id 用 UUID）。
  - `setConfigOption(id:"runtimeMode")`:更新 `runtimeMode` → `channel.send(setPermissionModeFrame(...))` → 回发 configChanged;若 `!connected` 只存值（下次 connect 的 spawn 参数带上）。
  - init 帧（`system/init`）里回读 `permissionMode` 字段校正 `runtimeMode`（防外部漂移；mapper 已捕获 init 帧——在 ClaudeFrameMapper `mapSystem` init 分支补一个 `.configChanged` 合并或直接在 session 层从 mapper 拿）。
  - respawn 路径（`load()` 的 `--resume` respawn、`reconnect()`）把当前档位传进 `shellCommand`/`argv`。
- [ ] **Step 4: `run-tests.sh` 全绿**
- [ ] **Step 5: Commit** `feat(claude): runtime permission-mode switching via control protocol`

### Task 4: web 档位 chip

**Files:**
- Modify: `swift-app/agent-web/src/App.tsx`（KNOB_ORDER + 图标映射，~1441-1447）

**Interfaces:**
- Consumes: adapter 下发的 `configOptions` 里 id=`runtimeMode` 的选项（现有 store/reducer 已泛化，无 store.ts 改动）。

- [ ] **Step 1:** `KNOB_ORDER` 加 `runtimeMode: 2`（排在 model 后 thinking 前）；Icon 映射加 `option.id === "runtimeMode" ? "mode" : ...`（复用现有 mode 图标）。
- [ ] **Step 2:** `cd swift-app/agent-web && npm run build` 通过；用 `/dev.html` + `__gotyStore.applyAll` 注入含 runtimeMode 的 configOptions 冒烟：chip 出现、四档可选、选择触发 `setConfigOption`（console 断言）。
- [ ] **Step 3: Commit** `feat(web): runtime-mode chip (generic config pipeline)`

### Task 5: manifest 一致性测试（happier 模式）

**Files:**
- Test: `swift-app/tools/agenttest.swift`

- [ ] **Step 1:** 断言：每个 adapter 的 `configOptions` 若含 `runtimeMode`，则其 capabilities 必须含 `.runtimeModes`（新 OptionSet 位，Task 2/3 顺手加上）；反之不含位者不得发该选项。三个 adapter（omp/pi/codex/claude）逐一断言当前真值。
- [ ] **Step 2:** 跑绿。**Step 3: Commit** `test(agent): manifest honesty for runtime modes`

### Task 6: 收尾

- [ ] `swift-app/run-tests.sh` + `build.sh` + `restart-app.sh`；手动冒烟：codex pane 切 auto 档发 turn（观察不再弹审批）、claude pane mid-session 切 acceptEdits（下一工具调用免问）。
- [ ] Commit（如有遗漏文件）。

---

## Phase 2+ 路线（每项开工时另写详细 plan，本节是范围锁定）

2. **模型设置目录化**（monocode ModelSettings）：per-model `settings[]`（effort/serviceTier/thinking/context），`AgentConfigOption` 已够表达——改 codex effort/serviceTier 进 turn/start、claude `setModel` 控制请求。文件：CodexSession/ClaudeSession/App.tsx。
3. **隔离 helper 标题生成**（monocode isolated spawn）：codex/claude 会话标题 = 首条提示截断的现状升级为旁路生成；`--no-session-persistence --strict-mcp-config`。文件：两 adapter + sessiond 无关。
4. **pi/omp 命令面补齐**（gooey-pi 词汇表）：`set_steering_mode / set_follow_up_mode / set_auto_compaction / set_auto_retry / get_branch_messages`，先 `omp --help` 确认档位 flag 再决定 omp runtimeMode 是否入 Phase 1 体系。文件：OmpSession/PiSession。
5. **subagent 嵌套转录**（paseo task_* 路由表）：claude `task_started/updated/notification` → 可展开子代理卡片。文件：ClaudeFrameMapper/AgentTypes/agent-web。
6. **usage/rate-limit 表**（monocode rateLimitsFetch）：codex `account/rateLimits/read`。文件：CodexSession/sessiond(远端)。

# 右栏 Terminal 设计（per-server side terminal）

日期：2026-08-30
状态：已与用户逐节确认

## 背景与目标

中心区同一时间只能呈现 focused tab 的内容，最高频的受限场景是：agent GUI 打满
工作区时，无处快速跑一条命令（git status、测试、tail）。调研（paseo / happier /
tty7，2026-08-30）结论：

- paseo 用中心 split 树 + 每 pane tab 栏，但其侧栏按 host/workspace 组织、不按
  repo 分组——"跨 space 组合"在它的模型里不存在。
- goty 的产品身份是 space（repo）为中心：侧栏分组、per-space `+`、Git 面板、
  Files 都挂在 space 上。中心多 tab 会让 space 从容器降级为标签，侧栏立刻面临
  一对多归属问题（orca 的按钮组方案即是在给这条语义裂缝打补丁）。
- happier 的右栏 tab 恰为 `git / files / navigation / agents / terminal`，终端
  即侧栏 dock，`workspace_shell` 模式在工作目录开 shell——直接先例。

因此 v1 不动中心区与 Spaces 语义，在右栏补一个 Terminal tab。

方案演进（两轮否决记录）：

- **per-space 绑定（否决）**：space 是派生对象（存在性 = ≥1 个 tab 的 cwd
  resolve 到该 root），销毁要靠收敛清扫、依赖异步 repoRoot 缓存；且 space
  消失后终端不可达，"保留"留隐形 shell、"杀死"要接受误关丢现场。复杂度全
  来自绑定键不稳定。
- **自动跟随 space cd（否决）**：shell 有状态，静默改写位置违背"这是我的
  shell"的预期，并毁掉"side terminal 挂 tail/dev server"的合法用法。
- **per-server 绑定（选定）**：server（`WorkspaceState`）是一等持久实体，
  有 UUID、随 park/restore/teardown 走、不会悄悄消失。绑定它，资源上界恒为
  0 或 1 个 / server。

## 已确认的产品决策

1. **每 server 至多一个**右栏终端；**惰性创建**——首次对该 workspace 打开
   Terminal tab 才建，space 出现、server 添加永不触发。
2. 它是一个**标准 goty-session**：`openPane` 建 PTY、runtimeId 寻址、replay
   ring、断线重连、GUI 退出后 reattach——keep/recover 与中心区终端完全一致。
3. **不随 space 切换内容**。Files 是视图、随 space 切换；terminal 是会话、
   属于 server。二者差异是有意为之。
4. 创建时 cwd = 当时的聚焦 space root；此后通过对位手段回到当前 space（见
   "cd 芯片"），不做自动跟随。
5. 面板头部显示 shell **实时 cwd**（daemon list 轮询回报），停在哪儿永远可见。
6. **显式关闭**（头部按钮，kill + 清字段）与用户敲 `exit` 同样进入空态
   （"打开新终端"），不自动重生。
7. 随 workspace **park/restore 原样走**（远端 server 移除保留会话）；
   `killWorkspace` 一并 kill。
8. **不可见性**：侧栏 Spaces、TabStripView、⌘T/⌘W 均不感知它。它不是 tab。
9. Terminal tab 使用**独立的右栏宽度记忆**（默认宽于 Files/Git）。

## 架构方案

- **选定**：`WorkspaceState` 上的 side-terminal 字段 + 专用 host 工厂复用
  `PaneHost` / hostPool / `paneDaemonTarget` + 右栏新增 Terminal tab。
  v1 存 `auxTerminalPaneId: String?`（单 pane）；v1.2 起存
  `auxTerminalPanes: [PaneState]`（与 tab panes 同一套 cell 几何，decode 时
  迁移旧单 id 字段）。per-space 多终端仍是独立课题。

## 1. 模型（`Sources/Core/Workspace/Models.swift`）

```swift
struct WorkspaceState: Codable {
    // …existing…
    /// 右栏 side terminal 的 pane id（惰性创建，sessiond 拥有进程）。
    /// nil = 该 server 还没开过。旧 state.json 无此键 → decode nil。
    var auxTerminalPaneId: String?
}
```

`decodeIfPresent`，与 `agentSessionId` 同模式；`WorkspaceStore` 的迁移 pass
不动。

## 2. 生命周期状态机

| 事件 | 行为 |
|---|---|
| 首次打开右栏 Terminal tab（该 workspace） | 创建：分配 pane id、`auxTerminalPaneId` 落盘，cwd = 当时聚焦 space root |
| 切 space / 切 tab / 折叠右栏 / 重启 app / GUI 崩溃 | 不动：host 隐藏存活（hostPool），state.json 的 pane id reattach + replay |
| 用户敲 `exit` / pane EXITED | 清字段、retire host、面板转空态；space 与 workspace 均不受影响 |
| 头部关闭按钮 | killPane + 清字段 + retire host + 空态 |
| `killWorkspace` | id 并入 kill 列表 |
| workspace 移除（park） | 字段随 `WorkspaceState` 原样进 parked；远端 daemon 上的 shell 继续跑，re-add 后重挂 |
| `reconnectWorkspace` / `retireHosts(workspace:)` | host 被 retire；面板在 `.structure` 后重新索要（hostPool miss → 新建 → replay 重挂），与中心区 pane 同规则 |

## 3. 右栏 UI（`Sources/UI/Panels/RightPanel.swift`）

- `RightPanelTab`（`Preferences.swift:11`，String enum）加 `case terminal` —
  UserDefaults 持久化向后兼容。
- 新 `TerminalPanelView`：
  - **头部一行**：实时 cwd 标签（次级色，路径尾段 + tooltip 全路径）、
    "cd → 当前 space" 芯片（见 §5）、关闭按钮（IconButton，destructive 语义
    走 `Dialog.confirm`）。
  - **挂载位**：容纳 `PaneHost`，frame 由面板约束驱动（pane grid 的 fraction
    布局不参与）；点击即聚焦 ghostty surface（surface 自带 click-focus）。
  - **空态**：居中 "已退出" 说明 + "打开新终端" 按钮 → coordinator 重建。
- 4 个 tab 后 `PanelTabButton` 文字标签空间不足：terminal 用图标（现有 glyph
  机制），Files/Git/Info 维持原样或统一切图标——实现时按 260pt 宽度实测定。
- **宽度**：`AppPreferences` 加 `terminalPanelWidth`（默认 400，clamp 同现有
  resize 行为）；`activate(tab:)` 切换时换宽度约束值，拖拽写回对应字段。

## 4. 接线

- **专用工厂** `makeAuxTerminalHost(ws:)`（AppDelegate）：`PaneHost(app:paneId:
  hostKey:cwd:daemonTarget:)`，`daemonTarget` 走现有 `paneDaemonTarget(wsId:)`
  （本地 singleton / 远端转发 daemon，路由现成）。回调只接 `onExited` /
  `onPaneGone` → `coordinator.auxTerminalExited(wsId:)`；`onTitle` /
  `onAgentState` 不接（无消费面）。hostPool 照常登记（teardown/reconnect 的
  `retireHosts(workspace:)` 因此天然覆盖它）。
- **`coordinator.auxTerminalExited(wsId:)`**：清 `auxTerminalPaneId`、
  `retireHost`、`.structure` 通知。
- **`paneExited` 开头加 aux 分支**：`paneId == workspace.auxTerminalPaneId`
  先行走 aux 路径并返回（现有实现只走 tabs，会静默 no-op）。
- **`killWorkspace`**（`WorkspaceCoordinator.swift:424`）：id 收集并入 aux id。
- **`applyForegrounds`**（`WorkspaceCoordinator.swift:237`）：迭代集并入 aux
  pane id——`onForegroundChange` 驱动其 `PaneHost.updateAgentCommand`，使
  `@ai` 触发器随 fg 变化正确 arming（在 vim/ssh 内不误触发），同时
  `isShellPrompt(fg)` 决定 cd 芯片可用态。
- **cwd 显示**：`pollDaemonLists` 的 `listPanes` 回报里按 runtimeId 取 aux
  pane 的 cwd，存 runtime 字段，`.cwd` 域通知头部刷新。
- **`refresh()` 的 liveKeys / keepAlive 不含 aux**：`PaneGridView` 从未拥有
  该 host（从未进 `setVisiblePanes`），不会被 grid retire；唯一 retire 来源
  是 `retireHosts(workspace:)`，面板重挂路径见状态机末行。

## 5. cd 芯片

- 目标 = `updateRightPanel()` 现算的 spaceRoot（与 Files 同一 resolver）。
- **门控**：runtime fg 为 shell（`PaneHost.isShellPrompt`）才启用；非 prompt
  （vim/ssh/运行中命令）禁用灰显。fail-closed：fg 未知时禁用。
- **注入**：`\u{15}` 清行 + `cd '<Shell.forceQuoted(path)>'` + `\r`（与
  `handleAITrigger` 的清行-注入同模式，防止拼进用户半行输入）。
- 注入只改 shell 的位置，不动任何持久状态；zsh 历史里出现一条 cd 属预期。

## 6. 远程与 park

- daemon 路由由 `paneDaemonTarget` 按 wsId 完成，远端即 ssh 转发的 sessiond
  （M2 已验证远端 pane 路径）；PTY、replay、重连全在远端。
- 断链：与中心区 pane 同规则——offline cover 覆盖中心区，side terminal 的
  host 走现有 disconnect → retry；link 恢复后 `retireHosts` + 重挂。
- park/restore：字段在 `WorkspaceState` 内，随 parked 列表原样走，re-add
  命中同 id → reattach。

## 7. 错误与边界

- daemon cold-start / socket 拒绝：`startSessionIfNeeded` 现有 1s 重试循环
  兜底，无需新代码。
- `killPane` 在断链时 fire-and-forget 失败：字段照清，远端进程由 daemon /
  server 侧自然回收（与现有 tab pane 行为一致）。
- 旧 state.json：无键 decode nil，首次打开即全新终端。
- 右栏整体折叠（width 0）：host 保留隐藏，`syncCoreVisibility` 现有路径
  暂停渲染。
- 单窗口应用，无多窗口争用问题。

## 8. 测试（`run-tests.sh` 无头体系）

- **Models**：旧 state.json（无 `auxTerminalPaneId`）decode 快照；带字段的
  round-trip。
- **Coordinator**：`ensureAuxTerminal` 幂等（已有 id 不重建、不换 cwd）；
  `auxTerminalExited` 清字段；`killWorkspace` 的 id 列表含 aux id；
  `applyForegrounds` 对 aux pane 产出 identity change；`paneExited` 对 aux
  pane 走 aux 分支（不触 tabs）。
- **cd 芯片**：门控纯函数快照（fg=zsh/vim/nil → enabled/disabled）；注入
  字节序列快照（含清行前缀与引号）。
- **UI seam**：Terminal tab 激活挂载 host；空态按钮触发重建；宽度按 tab
  切换；`retireHosts(workspace:)` 后面板重挂。
- 布局回归断言不变（不动区域约束——TerminalPanelView 内部自洽，遵守
  "region 内约束不出界" 的窗口铁律）。

## 9. 非目标（v1 明确不做）

- per-space 多 side terminal（升级路径保留，见架构方案）。
- 自动 cd、shell 退出自动重生、空闲回收。
- side terminal 出现在 TabStrip / 侧栏 / ⌘T ⌘W 的任何路径里。
- side terminal 内跑 agent 的 badge / AgentDetect UI（fg 轮询只服务 `@ai`
  门控与 cd 芯片；要跑 agent 请用中心区 terminal tab 或 agent GUI pane）。
- 中心区多 tab / 跨 space 组合（独立课题，另行立项）。

## 10. 变更记录

**2026-08-31（v1.5）：**
- **`@tty` 指令**（第三个触发器 kind）：在该 pane 的实时 cwd 新建 terminal tab。
  LineTrigger 的 `TriggerKind` 加 `.tty`（前缀 `@tty` 进 prefixes 表）；与 @agent 同
  门控（`agentArmed`——prompt 即武装，无需 provider 配置）、同清行动作（吞回车 +
  ctrl-u 清 shell 行）；**无 payload**——尾部文字忽略，裸 `@tty` 即触发。动作 =
  `coordinator.newTab(cwd:)`（侧栏 "+" 的 New Terminal 同路径，无需能力门控）。v1.4
  抽出的 `wireTerminalTriggers` 共用接线使**中心区与侧栏 terminal 都生效**——侧栏
  terminal 由此成为完整的 server 控制区（@omp 开 agent GUI、@tty 开 terminal、@ai
  就地提问）。历史召回（↑/ctrl-r 后回车）的 `matchFromScreenRow` 同样识别。
  命名定 `@tty`：unix 底座名词、与 @ai 同样简短小写、不与 agent key 冲突。

**2026-08-31（v1.4）：**
- **侧边终端接通 @omp/@ai**（spec §4 最初就为此把 fg 轮询并入 aux pane，但动作侧从未接线）。
  根因三处：① `aiTarget(for:)` 与 `cwd(ofPane:in:)` 只在 `ws.tabs` 里解析 pane，aux pane
  永远 miss——`updateAITrigger` 要求 feed 非 nil 才 arm @ai，于是一直不 arm；② aux host 工厂
  未接 `coordinatorFeed` / `onAITask` / `onAgentSessionTrigger`（@omp 会 arm 但触发即静默
  吞掉）。修复：两个解析器加 aux 兜底；触发接线抽成 `wireTerminalTriggers(host:ws:)`，
  中心/侧栏两个工厂共用。行为：`@omp/@pi/@claude…` → 中心区开 GUI agent session（cwd 取
  侧栏 pane 实时 cwd）；`@ai` → AI 卡片贴在该侧栏 pane 上（面板窄，卡片可挤——可拉宽面板）。

**2026-08-31（v1.3，实测反馈修订）：**
- **恢复头部路径显示与 cd 芯片**（v1.1 砍掉时的理由"Split 去中心区开新 space"已随
  v1.2 消失）。多 pane 后语义落在**聚焦 pane**上：点击面板内任一 pane
  （click monitor 的右栏腿，`focusAuxPane`——不污染中心区 activePaneId），头部
  显示该 pane 实时 cwd（尾段 + tooltip 全路径），cd 芯片门控在该 pane 的 fg
  为 prompt（`auxTerminalAtPrompt`），注入目标也是它；注入字节由
  `WorkspaceCoordinator.auxCdInjection` 纯函数生成（清行 + 引号 cd + 回车）。
- **修复关闭即重生**（v1.0 起的 latent bug，§2 一直要求"空态不自动重生"但实现
  没区分"从未打开"与"显式关闭"）：runtime 加 `auxClosed`——`closeAuxTerminal`
  与最后一个 pane 的 exit 置位，`ensureAuxTerminal`（打开新终端按钮）清除；
  创建门要求 `panes.isEmpty && !closed`。会话级易失，重启后首次打开 Terminal
  tab 正常重建。

**2026-08-31（v1.2，实测反馈修订）：**
- **右栏内真 split**（v1.1 的 Split 路由实测反直觉：手势在侧栏、动作却落在
  中心区新建 space）。`auxTerminalPaneId: String?` → `auxTerminalPanes:
  [PaneState]`（decode 迁移旧字段）；面板挂载位换成复用的 `PaneGridView`
  （fraction 布局 + hairline 分隔线 + per-host occlusion，零新代码）；
  `ghosttySplitRequested` 对 aux pane 改走 `splitAuxTerminal`（splitCells
  同一套几何，新 pane 继承源 pane 的实时 cwd——`applyCwds` 现在把 daemon
  回报写进 aux pane 的持久 cwd 字段）。逐 pane 的 `exit` 走
  `auxTerminalExited(wsId:paneId:)` 只移除自己；头部关闭按钮 = 关全部
  （`closeAuxTerminal`）。测试：layouttest 侧栏段重写（17 项）。
- v1.1 的"Split 路由到中心区新建 tab"路径整体移除（`auxTerminalCwd()` /
  `newTab(cwd:)` 路由删除）。

**2026-08-31（v1.1，实测反馈修订）：**
- 面板头部改为"收起侧栏时中心区顶部 tab 行"样式（28pt
  `chromeSurface(topBarBackground)` 全出血条带 + 条带式关闭按钮），surface
  紧贴条带之下。**§3 的 cwd 标签与 §5 的 cd 芯片整体移除**（未发布即回退）：
  面板定位收敛为"一个小 terminal 工作区"；`auxTerminalAtPrompt` /
  `setTerminalCwd` / `setTerminalCd` 及相关测试随之删除。`auxTerminalCwd`
  保留，用途变更见下。
- **Split 路由**：侧边终端上 ghostty 原生右键 Split（或 keybind）不再静默
  no-op——`ghosttySplitRequested` 识别 aux pane 后改在中心区新建 terminal
  tab，cwd 取侧边终端实时 cwd（`auxTerminalCwd()`）。侧栏内不做真 split
  （等同放弃 per-server 单终端决策）。
- 修复：挂载竞态（值拷贝 `ws` 导致挂上即被卸下）、空态按钮幂等死路
  （ensure 后补一次 mount）、关闭按钮无尺寸约束、挂载后未重推
  `syncCoreVisibility` 导致渲染器停摆（空白终端）。

# CLAUDE.md

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.  

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

---

## 分层与模块化（用户长期要求，2026-08-23 起绑定）

上下三层，代码评审按此判：

1. **界面与逻辑分离**：决策规则放 Core（纯函数、无 AppKit view、
   可无头测试——如 `Core/Files/TreeOps.swift`）；视图只执行计划、
   不藏规则。一个功能的逻辑改动不应触碰任何视图文件，反之亦然。
2. **模块与子模块分离**：每个面板/区域一个目录
   （`UI/Panels/Files/`、`UI/Panels/Git/`…），目录内一类一个文件
   （视图、行组件、编辑行组件、容器）。跨模块只经所属模块的门面
   类型，不伸手进别的模块的子组件。
3. **模块与底层公共功能分离**：公共机制（keyed 行和解、
   FileSource 传输、Dialog、HighlightEngine）不知道使用方是谁；
   模块不复制公共机制，改动公共机制时零业务知识带入。

背景事件（连接重试、轮询）只更新自己域拥有的表面；焦点只跟随
用户动作。行有稳定身份（keyed reconciliation），重渲染不得更换
活实例。

**度量的校准（用户 2026-08-23）**：以上服务的目标是"一个模块的
开发不影响其他模块"。分层是手段不是仪式——简单的代码保持简单，
不为分层而复杂化；判据是隔离效果，不是层数。

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.
- **Evaluate user proposals against current implementation and target requirements before executing. Do not follow blindly.**

---

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

---

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

Additional principles:
- **Fix bugs by identifying root causes, not applying workarounds.**
- **Explore upward (callers, architecture, data flow) to find general solutions.**
- **After fixing, clean up any obsolete or workaround code introduced during debugging.**

The test: Every changed line should trace directly to the user's request.

---

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```
Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

## 5. Architecture & Reusability

**Build features that fit the system, not just solve the task.**

When implementing new features:
- Follow the existing project structure and architecture.
- Reuse existing modules, utilities, and patterns whenever possible.
- Avoid duplicating logic that already exists elsewhere.
- Ensure new code integrates naturally into current directory and module design.

Balance principles:
- **Prefer separation of concerns, but avoid over-engineering.**
- **Avoid excessive abstraction that reduces readability.**
- **Aim for clean, cohesive modules instead of fragmented micro-components.**

The goal: code that is reusable, consistent, and easy to evolve — without unnecessary complexity.

---

**These guidelines are working if:**
- Fewer unnecessary changes in diffs
- Fewer rewrites due to overcomplication
- Bugs are fixed at root cause, not patched
- New features align naturally with existing architecture
- Clarifying questions come before implementation rather than after mistakes

# goty 工作原则（用户明确要求，长期有效）

1. **稳定而精致**：产品必须先稳定、再精致。任何改动两者都要顾及；渲染/终端核心链路（tmux 控制协议、ghostty surface 生命周期）的回归优先于一切功能。

2. **第一性原理排障**：任何 bug/问题必须先分析 rootcause（根本原因）→ 直接原因 → 然后修复。**禁止**叠加补丁代码、重试循环、workaround、等待/延迟类的"缓解"方案。如果发现自己在写 retry/timeout/sleep 来"绕过"问题，停下来重新找根因。

3. **组件复用与样式一致化**：同类 UI 必须组件化后复用（如 IconButton、SidebarRowView、HairlineView、ChromeTheme），新增 UI 先找现有组件；视觉规格（点大小、颜色 token、间距、hover 行为）集中在组件与主题里定义，禁止在调用点散落内联样式。引入新样式前先问：能否扩展现有组件/主题令牌？

4. **性能是一级目标**：任何功能添加都必须保证性能（对标 Ghostty/Alacritty 的流畅度；tty7 的 benchmark 是参考）。渲染热路径零分配拷贝、控制协议往返最小化、UI 交互零可感知延迟；引入功能前先想它对 typing latency / 大输出 cat / 帧率的影响。

## 代码组织与架构规范（2026-08-22 编辑器布局事故后重构确立）

### 目录结构（模块文件夹；新文件先归对模块）

```
Sources/App/      组装层
  AppDelegate           生命周期/菜单/快捷键/监视器；逻辑转发 coordinator
  AppWindowController   窗口合成根：外壳 + 三个区域容器 + 区域开合状态机
  AppLog              vendored Ghostty 引用的日志桩
Sources/Core/     纯逻辑，零视图
  Workspace/  Files/  Git/  Agents/   + Preferences.swift + Shell.swift
Sources/UI/
  Chrome/（主题令牌） Components/（共享原语）
  Sidebar/  Terminal/  Panels/（RightPanel/FilesPanel/ScmPanel）
```

### 区域边界铁律（2026-08-22 事故的结构性答案）

- **全 app 唯一允许跨区域约束的地方 = `AppWindowController`**：sidebar /
  terminalArea / rightPanel 三区域只有那十几条边界约束，永不增长。
- **任何组件的约束只准引用自己容器内部的锚**。区域容器有确定 frame，
  子树内部怎么约束都伤害不到窗口——叶子功能最多坏自己，永远坏不了整窗。
  （事故复盘：一个编辑器 overlay 的约束曾把整窗布局打崩且根因无法隔离。）
- **终端区 overlay 只经 `TerminalAreaView.presentOverlay/dismissOverlay`**：
  overlay 永远住在终端区域内部，根不感知。编辑器回归时必须走这条路，并先
  在 `run-tests.sh` 里加 overlay 断言。
- 面板开合（⌘B/⌘J）全部经 `wc.toggleSidebar/toggleRightPanel` 一处状态机；
  禁止任何视图自行改 width 常量或直接操作 expand chrome。

### 布局回归测试（提交 UI 改动前必跑）

```sh
swift-app/run-tests.sh    # headless：区域图不退化、不重叠；开合往返；
                          # 重型 overlay 不得移动任何区域（事故的蒸馏用例）
```

### 弹框与事件循环铁律（2026-08-23 两次弹框卡死——host picker、
### worktree——同根复盘后确立）

- **弹框一律走 `Dialog` 的系统模态会话**（自有 borderless panel +
  `NSApp.runModal`）。禁止手搓嵌套 runloop 轮询当"模态"：从 NSMenu
  动作里启动时，事件流仍归菜单 tracking session 所有，轮询循环收不到
  按钮点击 = 画得出、点不动、整窗卡死。
- 菜单动作里弹框直接调 `Dialog` 即可——模态会话与 tracking 的交接由
  AppKit 保证（NSAlert 同款机制）。一跳 `DispatchQueue.main.async`
  只是"菜单先收尾"的排序惯例（同 SSH manager 入口），**不是**死锁
  修复；不得再以它代替机制修复。
- **headless 盲区**：`Dialog.presenterOverride` 让所有无头测试绕过真实
  呈现——改 `Dialog` 机制后测试全绿不能证明不卡，必须真机把触发路径
  点一遍才能提交（弹框 = 事件循环语义，run-tests.sh 结构上测不到）。

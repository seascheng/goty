# Terminals 顶层区 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 与 SPACES 同级的 Terminals 顶层区承载"与目录无关"的自由终端;SPACES 保持动态 cwd 分组不动。

**Architecture:** `TabState` 加 `freeTerminal: Bool`(自定义 decoder 缺省 false,零迁移);`SpaceGrouping` 摘离 free tabs;Sidebar 加第三区(termHeader/termStack);⌘T 与 Terminals"+"建 free tab;SPACES"+"改开 New Space 面板(DialogCard:路径输入,本地 NSOpenPanel 浏览、远程 `test -d` 校验);跨区拖拽置/清标记。

**Tech Stack:** Swift/AppKit;测试走 `swift-app/tools/layouttest.swift`(headless 断言,`./run-tests.sh` 跑)。

**Spec:** `docs/specs/2026-09-04-terminals-section.md`

## Global Constraints

- 旧 `state.json` 解码:缺 `freeTerminal` 键必须落 `false`(自定义 `init(from:)`,`decodeIfPresent`)。
- SPACES 的动态 cwd 分组行为**零改动**;`@tty`/`@omp`/`@ai` 触发路径零改动。
- 右侧 file 面板与 @ai 执行目标继续读 pane live cwd。
- 检查链:`cd swift-app && ./build.sh`(无新警告)→ `./run-tests.sh` 全过 → `./restart-app.sh`。
- 每任务独立提交,消息格式 `feat(sidebar)/feat(workspace): …`。

---

### Task 1: TabState.freeTerminal 字段(解码兼容)

**Files:**
- Modify: `swift-app/Sources/Core/Workspace/Models.swift`(TabState,~77-101)
- Test: `swift-app/tools/layouttest.swift`

**Interfaces:**
- Produces: `TabState.freeTerminal: Bool`(成员初始化器追加带默认值参数 `freeTerminal: Bool = false`;TabState 目前无手写 memberwise 使用——所有创建点在 WorkspaceCoordinator.appendTab 等,不传即 false)。

- [ ] **Step 1: 写失败测试**(layouttest 合适区——搜 `check(` 密集处尾部追加)

```swift
// Terminals 顶层区:旧 state 无 freeTerminal 键必须解出 false(零迁移)。
do {
    let json = #"{"id":"t1","name":"1","panes":[],"focusedIndex":0,"userTitle":null,"agentTitle":null,"paneCommand":null,"color":null,"icon":null}"#
    let old = try JSONDecoder().decode(TabState.self, from: Data(json.utf8))
    check(old.freeTerminal == false, "legacy TabState decodes freeTerminal=false")
    let new = TabState(id: "t2", name: "2", panes: [])
    check(new.freeTerminal == false, "memberwise default freeTerminal=false")
} catch {
    check(false, "TabState decode threw: \(error)")
}
```

注:若 TabState 的 memberwise init 已被带默认参数的调用点使用,直接编译验证;`panes: []` 按 PaneState 需要 `PaneState(id:cwd:)` 至少一个元素更真实——用 `panes: [PaneState(id: "p1", cwd: nil)]`。

- [ ] **Step 2: 跑测试确认失败**

Run: `cd swift-app && ./run-tests.sh 2>&1 | tail -3`
Expected: 编译失败 `value of type 'TabState' has no member 'freeTerminal'`

- [ ] **Step 3: 实现**——TabState 加字段 + 自定义 decoder(参照同文件 PaneState.init(from:) 的写法,64-74 行):

```swift
struct TabState: Codable {
    let id: String
    var name: String
    var userTitle: String? = nil
    var agentTitle: String? = nil
    var panes: [PaneState]
    var paneCommand: String?
    var color: String?
    var icon: String?
    /// 自由终端:属于顶层 Terminals 区,不参与目录分组。pane 的
    /// live cwd 只喂右侧 file 面板与 git 徽章。旧 state 无此键 → false。
    var freeTerminal: Bool = false

    private enum LegacyKeys: String, CodingKey {
        case id, name, userTitle, agentTitle, panes, paneCommand, color, icon
        case freeTerminal
    }

    init(id: String, name: String, panes: [PaneState], paneCommand: String? = nil,
         freeTerminal: Bool = false) {
        self.id = id; self.name = name; self.panes = panes
        self.paneCommand = paneCommand
        self.freeTerminal = freeTerminal
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LegacyKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        userTitle = try c.decodeIfPresent(String.self, forKey: .userTitle)
        agentTitle = try c.decodeIfPresent(String.self, forKey: .agentTitle)
        panes = try c.decode([PaneState].self, forKey: .panes)
        paneCommand = try c.decodeIfPresent(String.self, forKey: .paneCommand)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        freeTerminal = try c.decodeIfPresent(Bool.self, forKey: .freeTerminal) ?? false
    }
}
```

保留现有调用点兼容:凡 `TabState(id:name:panes:)` 构造(WorkspaceCoordinator 624/653/1026 等)不传新参即 false。若现有代码用了 `userTitle:`/`color:` 等标签的 memberwise 调用,把对应参数补进显式 init(带默认值)。

- [ ] **Step 4: 跑测试通过**

Run: `cd swift-app && ./run-tests.sh 2>&1 | tail -3`
Expected: `layouttest: all passed`(或既有汇总行)

- [ ] **Step 5: Commit** — `git commit -m "feat(workspace): TabState.freeTerminal (legacy-decode-safe)"`

---

### Task 2: SpaceGrouping 摘离 free tabs

**Files:**
- Modify: `swift-app/Sources/Core/Workspace/Models.swift`(SpaceGrouping,169-196)
- Test: `swift-app/tools/layouttest.swift`

**Interfaces:**
- Produces: `SpaceGrouping.freeIndices(in tabs: [TabState]) -> [Int]`;`sections(for:)` 内部排除这些 index。

- [ ] **Step 1: 失败测试**

```swift
// Terminals 区:free tabs 被摘离,不进目录分组。
do {
    let mk: (String, String?) -> TabState = { id, cwd in
        TabState(id: id, name: id, panes: [PaneState(id: id + "-p", cwd: cwd)],
                 freeTerminal: id.hasPrefix("f"))
    }
    let tabs = [mk("a", "/repo"), mk("f1", "/repo"), mk("b", nil), mk("f2", "/other")]
    check(SpaceGrouping.freeIndices(in: tabs) == [1, 3], "freeIndices picks free tabs")
    let secs = SpaceGrouping.sections(for: tabs)
    check(secs.flatMap(\.tabIndexs).sorted() == [0, 2], "sections exclude free tabs")
} catch { check(false, "threw: \(error)") }
```

- [ ] **Step 2: 跑测试确认失败**(`freeIndices` 不存在,编译错)

- [ ] **Step 3: 实现**

```swift
/// 顶层 Terminals 区的成员:freeTerminal tabs 在 sections 之前摘离。
static func freeIndices(in tabs: [TabState]) -> [Int] {
    tabs.indices.filter { tabs[$0].freeTerminal }
}
```

`sections(for:)` 开头:`let free = Set(freeIndices(in: tabs))`,keys 计算与 sections/scratch 的 index 过滤全部跳过 `free.contains($0)`。空结果路径(`order.isEmpty` 的 headerless section)同样排除。

- [ ] **Step 4: 测试通过**(注意:现有 layouttest 对 sections 的断言用的是无 free tab 的数据,应全保持绿)

- [ ] **Step 5: Commit** — `git commit -m "feat(workspace): SpaceGrouping separates free-terminal tabs"`

---

### Task 3: coordinator 入口(⌘T=free、setTabFree)

**Files:**
- Modify: `swift-app/Sources/Core/Workspace/WorkspaceCoordinator.swift`(newTab 720-728、appendTab 760-784)
- Test: `swift-app/tools/layouttest.swift`

**Interfaces:**
- Produces:
  - `func newTab()` → 建 `freeTerminal: true` 的 tab(初始 cwd 仍 `activeCwd()`)
  - `func newTab(cwd: String?)` → 现状(非 free)——`@tty`/目录组"+"/New Space 全走它
  - `func setTabFree(wsId: UUID, tabId: String, free: Bool)`(拖拽跨区提交)
  - `appendTab(name:command:cwd:kind:agentSessionId:free:) -> String?`(新参,缺省 false)

- [ ] **Step 1: 失败测试**(layouttest 里 coordinator 测试区,搜既有 `coordinator` 用例仿造构造)

```swift
// ⌘T 建 free tab;setTabFree 翻转并持久化到 store。
// (仿照该区已有的 coordinator 种子代码构造 store/coordinator)
let before = coordinator.store!.workspaces[0].tabs.count
coordinator.newTab()
let ws = coordinator.store!.workspaces[0]
check(ws.tabs.count == before + 1 && ws.tabs.last!.freeTerminal,
      "newTab() creates a free-terminal tab")
coordinator.setTabFree(wsId: ws.id, tabId: ws.tabs.last!.id, free: false)
check(coordinator.store!.workspaces[0].tabs.last!.freeTerminal == false,
      "setTabFree clears the flag")
```

- [ ] **Step 2: 确认失败**

- [ ] **Step 3: 实现**——`newTab()` 改 `appendTab(name: nil, command: nil, cwd: activeCwd(), free: true)`;appendTab 加参并透传给 TabState 构造;`setTabFree`:

```swift
/// 拖拽跨区提交:Terminals ⇄ SPACES 的成员迁移。
func setTabFree(wsId: UUID, tabId: String, free: Bool) {
    guard let store,
          let wi = store.workspaces.firstIndex(where: { $0.id == wsId }),
          let ti = store.workspaces[wi].tabs.firstIndex(where: { $0.id == tabId }),
          store.workspaces[wi].tabs[ti].freeTerminal != free else { return }
    store.workspaces[wi].tabs[ti].freeTerminal = free
    store.save()
    delegate?.coordinatorDidChange(.structure)
}
```

split(`splitPane`)在既有 tab 上加 pane,tab 级标记天然继承——不改。

- [ ] **Step 4: 测试通过**
- [ ] **Step 5: Commit** — `git commit -m "feat(workspace): ⌘T creates free terminals; setTabFree drag commit"`

---

### Task 4: Sidebar Terminals 区(UI + 渲染)

**Files:**
- Modify: `swift-app/Sources/UI/Sidebar/Sidebar.swift`(init 514-585、render ~676-888、`sectionHeader` lazy 区 334-494、`setCollapsed` 653-660)
- Test: `swift-app/tools/layouttest.swift`

**Interfaces:**
- Consumes: Task 2 `freeIndices`、Task 3 `newTab()`/`setTabFree`
- Produces: `var onCrossSectionDrop: ((Int, Bool) -> Void)?`(tabIndex, toFree——Task 5 消费);`termRowsForTest: [NSView]`。

- [ ] **Step 1: 失败测试**

```swift
// Terminals 区渲染:free tabs 落 termStack,SPACES 目录组不含它们。
// (沿用该区已有的 wc/sidebar.render(workspace:…) 种子模式;渲染前把
//  workspace.tabs[1].freeTerminal = true)
ws.tabs[1].freeTerminal = true
wc.sidebar.render(workspace: ws, statusFor: { _ in nil },
                  commandFor: { _ in nil }, titleFor: { _ in "t" })
check(wc.sidebar.termRowsForTest.count == 1, "one row in the Terminals section")
check(!wc.sidebar.tabsRowsForTest.contains { ($0 as? SidebarRowView)?.tabIndex == 1 },
      "SPACES rows exclude the free tab")
```

- [ ] **Step 2: 确认失败**(`termRowsForTest` 不存在)

- [ ] **Step 3: 实现**
  - 成员:`private let termStack = NSStackView()`;`private lazy var termHeader: NSView = sectionHeader("Terminals", plus: { [weak self] _ in self?.onNewTab?() }, emphasized: true)`;`private let divider2 = NSView()`(复制 divider 样式)。
  - init:`for (stack, head) in […]` 数组加入 `(termStack, termHeader)`;约束链改为 `divider → termHeader → termStack → divider2 → tabsHeader → tabsStack`(常量沿用 10/8)。
  - `setCollapsed`:同步 termHeader/termStack/divider2。
  - render:在 `SpaceGrouping.sections` 调用前 `let freeIdx = SpaceGrouping.freeIndices(in: workspace.tabs)`;signature 里 free 行的 space 段写 `"terminals"`(防 diff 复用抖动);循环渲染 free 行到 termStack(`pin(row, to: termStack)`),`spaceKey: "terminals"`,onClose/onRename/onSetColor 等回调与目录组行同款(tabIndex 原值)。目录组渲染代码不动(sections 已排除 free)。
  - 清理:既有 `nextSectionViews`/row 复用管线把 termStack 的行也纳入(或 free 行走简单重建——行少,重建可接受;但 signature 抑制逻辑要含 termStack,防闪烁)。
  - `var termRowsForTest: [NSView] { termStack.arrangedSubviews }`
  - termHeader 的"+"用 `onNewTab`(= coordinator.newTab(),⌘T 同路);SPACES tabsHeader 的 plus **暂不动**(Task 6 换绑 New Space)。

- [ ] **Step 4: 测试通过;`./build.sh` 无新警告**
- [ ] **Step 5: Commit** — `git commit -m "feat(sidebar): top-level Terminals section"`

---

### Task 5: 跨区拖拽(置/清 freeTerminal)

**Files:**
- Modify: `swift-app/Sources/UI/Sidebar/Sidebar.swift`(drag 管线 198-332)
- Modify: `swift-app/Sources/App/AppDelegate.swift`(sidebar 回调接线区,~817)
- Test: `swift-app/tools/layouttest.swift`

**Interfaces:**
- Consumes: Task 3 `setTabFree`、Task 4 `onCrossSectionDrop`
- Produces: 无(Sidebar 内部:drop 判定 + 回调)

- [ ] **Step 1: 失败测试**

```swift
// 跨区 drop:目录组行 → Terminals 区体 = 置 free;反向 = 清除。
var dropped: [(Int, Bool)] = []
wc.sidebar.onCrossSectionDrop = { idx, toFree in dropped.append((idx, toFree)) }
// 模拟 mouseUp 时的落点判定(纯函数,同 reorderMove 的测试模式):
check(Sidebar.dropTarget(forGlobal: .zero, term: NSRect(x: 0, y: -10, width: 10, height: 10),
                         spaces: NSRect(x: 100, y: 0, width: 10, height: 10)) == .terminals,
      "global point inside term rect targets terminals")
```

- [ ] **Step 2: 确认失败**

- [ ] **Step 3: 实现**
  - 纯函数:`enum DropZone { case terminals, spaces, none }`,`static func dropTarget(forGlobal p: NSPoint, term: NSRect, spaces: NSRect) -> DropZone`(containment 判定)。
  - drag 管线:`mouseDragged` 存最新 `NSEvent.mouseLocation`(converted);`mouseUp` 里若 dragRow 的 spaceKey 与落点区不同且 `dropTarget != .none` → `onCrossSectionDrop?(row.tabIndex!, 落区 == .terminals)`,跳过 stack 内 reorder。跨区时不需要 live preview(行少),只需 cursor 提示(v1 可无高亮)。
  - AppDelegate 接线:`sidebar.onCrossSectionDrop = { [weak self] idx, toFree in guard let ws = self?.coordinator.store?.focused else { return }; self?.coordinator.setTabFree(wsId: ws.id, tabId: ws.tabs[idx].id, free: toFree) }`。
  - Terminals 区内排序:现有 spaceKey 过滤逻辑天然支持(`spaceKey == "terminals"` 的兄弟)。

- [ ] **Step 4: 测试通过**
- [ ] **Step 5: Commit** — `git commit -m "feat(sidebar): drag tabs across the Terminals/Spaces boundary"`

---

### Task 6: New Space… 面板(SPACES"+")

**Files:**
- Create: `swift-app/Sources/UI/Components/NewSpaceCard.swift`(DialogCard 子类,参照 WorktreeCard)
- Modify: `swift-app/Sources/UI/Sidebar/Sidebar.swift`(tabsHeader plus 换绑)、`swift-app/Sources/App/AppDelegate.swift`(回调 + 面板触发)
- Test: `swift-app/tools/layouttest.swift`

**Interfaces:**
- Consumes: `Dialog.presentCard`、`Shell.exec(_:host:)`、`coordinator.newTab(cwd:)`
- Produces: `final class NewSpaceCard: DialogCard`(`init(host: String?, onConfirm: (String) -> Void)`;host nil = Local);`Sidebar.onNewSpace: (() -> Void)?`。

- [ ] **Step 1: 失败测试**(纯逻辑部分:路径校验)

```swift
// New Space 路径判定:~ 展开、空路径拒绝。(纯函数暴露给测试)
check(NewSpaceCard.expanded("~/x") == NSHomeDirectory() + "/x", "~ expands")
check(NewSpaceCard.validLocal(NewSpaceCard.expanded("~/..")) , "existing dir passes")
check(!NewSpaceCard.validLocal("/no/such/dir-goty-test"), "missing dir fails")
```

- [ ] **Step 2: 确认失败**

- [ ] **Step 3: 实现**
  - `NewSpaceCard`:标题 "New Space";一行 ChromeInput(路径,placeholder "~/projects/foo");状态行(muted,校验结果红字);Local 时"浏览…"按钮(NSOpenPanel `canChooseDirectories`);主按钮 "Create"。确认时:本地 `FileManager.fileExists(isDirectory:)`;远程 `DispatchQueue.global` 上 `Shell.exec("test -d " + Shell.quoted(path), host: host)` 回主线程;失败 → 状态行红字,不关面板;成功 → `onConfirm(展开后的绝对路径)` 并关。
  - Sidebar:`tabsHeader` 的 plus 换为 `self?.onNewSpace?()`;新回调属性。
  - AppDelegate:`sidebar.onNewSpace = { [weak self] in guard let ws = self?.coordinator.store?.focused else { return }; Dialog.presentCard(NewSpaceCard(host: ws.sshHost) { path in self?.coordinator.newTab(cwd: path) }, width: NewSpaceCard.cardWidth) }`。
  - 深色样式沿用 DialogCard/Chrome 体系;不新增设计语言。

- [ ] **Step 4: 测试通过;`./build.sh` 无新警告**
- [ ] **Step 5: Commit** — `git commit -m "feat(sidebar): New Space panel on the SPACES '+'"`

---

### Task 7: git 徽章联动 + 全链验证

**Files:**
- Modify: `swift-app/Sources/UI/Sidebar/Sidebar.swift`(render 的 free 行 git 参数)或 AppDelegate 侧 gitFor 提供(视现有管线位置)
- Test: `swift-app/tools/layouttest.swift`

**Interfaces:**
- Consumes: 前六任务全部。

- [ ] **Step 1: 失败测试**

```swift
// Terminals 区 tab 的 git 徽章跟 pane live cwd(cd 进 repo 显示分支)。
ws.tabs[1].freeTerminal = true
// gitFor 供给("/live/repo" → branch "main"):
wc.sidebar.render(workspace: ws, gitFor: { cwd in
    cwd == "/live/repo" ? GitSummary(branch: "main", added: 0, removed: 0) : nil }, …)
check((wc.sidebar.termRowsForTest.first as? SidebarRowView)?.gitSummaryForTest?.branch == "main",
      "free row badge follows live cwd")
```

(若 SidebarRowView 无 gitSummaryForTest,补一个 internal 测试 accessor。)

- [ ] **Step 2: 确认失败**
- [ ] **Step 3: 实现**——free 行渲染时 `git: tab.panes.first?.cwd.flatMap(gitFor)`(目录组行现状不动)。
- [ ] **Step 4: 手工验证**:`./build.sh && ./run-tests.sh && ./restart-app.sh` 后——⌘T 出现在 Terminals 区;该 tab `cd` 到别的目录不挪区、file 面板跟随;`@tty` 仍建目录组 tab;拖拽跨区迁移;SPACES"+"弹 New Space(本地浏览可用);远程输入不存在路径红字。
- [ ] **Step 5: Commit** — `git commit -m "feat(sidebar): Terminals rows badge follows live cwd; full path verified"`

---

## Self-Review(已跑)

- **Spec 覆盖**:§数据模型=T1;§分组=T2;§入口表=T3/T4/T5(@tty 不动=无任务,正确);§New Space=T6;§联动=T7(file 面板/@ai 零改动=无任务);§边界:断连态走既有渲染(无新任务)、关闭/重命名/颜色同权=T4 行复用、split 继承=T3 说明;§测试清单逐条落在 T1-T7。
- **占位符**:无 TBD/“适当处理”。
- **类型一致性**:`freeTerminal`/`freeIndices`/`setTabFree`/`onCrossSectionDrop`/`onNewSpace`/`NewSpaceCard.expanded|validLocal|cardWidth` 各任务间签名一致。

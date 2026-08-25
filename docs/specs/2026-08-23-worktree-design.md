# Worktree 支持设计

日期：2026-08-23
状态：已与用户逐节确认

## 背景与目标

侧栏的 space（按 tab cwd 分组的项目目录区块）头部有 `+` 按钮，当前行为是
直接在该目录新建一个 terminal tab。Git worktree 是同级高频操作，本设计把
`+` 升级为条件菜单，并给右侧 Git 面板补齐 worktree 的查看与基本操作。

已确认的产品决策：

1. **目录命名**：worktree 建在项目 repo root 的父目录下，命名为
   `<项目名>-<名字>`。例：项目 `~/code/goty`，命名 `fix-login` →
   `~/code/goty-fix-login`。
2. **分支策略**：自动建同名分支，基于当前 HEAD
   （`git worktree add -b <名字> <路径>`）。同名分支已存在时报错提示换名。
3. **面板操作范围**：列表 + Open + Merge + Remove（不做 prune/重命名等）。
4. **远程支持**：ssh space 同样支持（transport 本地/远程同构）。
5. **创建后跳转**：在 worktree 目录新开一个 terminal tab 并聚焦；侧栏按
   cwd 分组自动出现新 space 区块。

## 架构方案（已选定 A）

- **A（选定）**：新增 `Core/Git/Worktree.swift` 纯逻辑（路径计算、名字
  校验、porcelain 解析、`WorktreeOp` 纯 argv 构造），执行复用 `ScmStore`
  串行队列与 `ScmTransport`。UI 只做菜单/弹框/面板行。
- B（否决）：UI 层直接拼 shell——违反分层铁律，无法无头测试。
- C（否决）：下沉 sessiond——git 已在 app 侧，IPC 往返无收益。

## 1. Core：`Sources/Core/Git/Worktree.swift`（新文件，零视图）

```swift
struct WorktreeRecord: Equatable {
    let path: String          // 绝对路径
    let branch: String?       // 短名（剥掉 refs/heads/）；detached/bare 为 nil
    let detached: Bool
    let bare: Bool
    let isMain: Bool          // 第一条记录 = 主 worktree
}

enum WorktreeList {
    /// 解析 `git worktree list --porcelain` 输出（纯函数，fixture 可测）。
    static func parse(_ porcelain: String) -> [WorktreeRecord]
}

enum WorktreePlan {
    /// root=/Users/x/code/goty + name=fix-login
    /// → /Users/x/code/goty-fix-login
    /// 以 repo root 为准（space 的 cwd 可能是子目录，不受影响）。
    static func target(root: String, name: String) -> String

    /// 分支安全名校验：拒空、纯空白、含 "/"、".."/前导 "-"、~ ^ : ? * [ \
    /// 与控制字符。返回错误描述或 nil。
    static func validateName(_ s: String) -> String?
}

enum WorktreeOp {   // 与 ScmOp 同形：label / loss / commands()
    case create(path: String, branch: String)   // git worktree add -b <branch> <path>（基于 HEAD）
    case merge(branch: String)                  // git merge <branch> --no-edit
    case remove(path: String)                   // git worktree remove <path>（无 --force）
}
```

- `create` 从 repo root 执行；失败（分支已存在、目录被占用、非法字符绕过）
  时把 git stderr 首行原样弹给用户。
- 引号统一走 `ScmTransport.join` / `Shell.forceQuoted`（远程路径同样安全）。

## 2. 数据获取：piggyback 同一次往返

`ScmStore.refreshStatus` 的命令链追加 `git worktree list --porcelain`，
两段输出用哨兵字符 `\u{1F}`（unit separator）分隔。一次 sh/ssh 往返同时
拿到 status + worktrees（远程省一次 RTT，本地省一次 fork）。

- `ScmStatus` 增加 `worktrees: [WorktreeRecord]` 字段。
- 侧栏的 `GitStatusStore`（分支/diff 摘要）不动，不掺 worktree。

## 3. 侧栏 `+` 菜单

点击时查 `gitFor?(dir)`（GitStatusStore 缓存）：

- **是 git 库** → NSMenu（照 `serverMenu()` 模式，锚在 + 旁）：
  `New Terminal` / `New Worktree…`。
- **非 git 或状态未知** → 维持现状：直接新建 terminal。未知只是 2s 轮询
  未落地的小窗口，降级行为无害；不做异步等待菜单。
- dir 为 nil（Scratch 区块）不提供 Worktree。
- `SidebarView` 新增回调 `onNewWorktreeInDir: ((String?) -> Void)?`，
  由 AppDelegate 装配，Coordinator 不感知菜单。

## 4. 创建流程（弹框）

1. 点 `New Worktree…`：若 `ScmStore.repoRoot(cwd:host:)` 未知，先
   `refreshStatus(force: true)`，落地后再弹框（一般已缓存，瞬时）。
2. `Dialog.prompt` 扩展 `detail:` 参数（`present()` 已支持 detail +
   prompt 组合，仅暴露）：标题 `New Worktree`，detail 显示完整目标路径
   与将创建的分支名，placeholder 是名字。非法名字在弹框层拦截。
   （v2 起由 `WorktreeCard` 取代 —— 行内校验 + 联动预览，见上。）
3. 确认 → `ScmStore.run(.create)`。
   - 成功：`invalidate` 现有机制刷新全部缓存；在该 workspace
     `newTab(cwd: <worktree 路径>)` 并聚焦——即"跳到这个目录"。
   - 失败：`Dialog.error` 显示 git stderr 首行。

> 2026-08-24 v2：创建弹框升级为专用 `WorktreeCard`（480pt 卡片：repo
> 上下文、随输入联动的目标路径预览、行内校验、校验门控的 Create
> 按钮），经 `Dialog.presentCard` 呈现；`ChromeInput.focus` 同时修复了
> 模态呈现时光标不闪烁的问题（插入点定时器在 key 转换完成前启动会被
> 丢弃，现在显式重启）。

## 5. Git 面板 Worktrees 组

`ScmPanelView` 底部新增可折叠 "Worktrees" 组（复用 `ScmGroupHeaderView`
折叠/hover 模式），数据来自 `status.worktrees`（含 app 外创建的）。

行内容：分支名（detached/bare 显示路径尾段）+ 次级灰色路径 + 主 worktree
标记；当前 repo root 对应行加"this"标识。hover 出 verbs（照
`ScmEntryRow` action strip 模式）：

- **Open**：在该 worktree 目录开 terminal tab。经 `onOpenWorktree` 回调 →
  `coordinator.newTab(cwd:)`；面板跟随聚焦 workspace，路由正确，远程同理。
  bare 行禁用。
- **Merge**：把该行分支 merge 进面板当前仓库的当前分支（`--no-edit`）。
  禁用条件：该行是当前 repo root / detached / bare / 与当前分支同名。
  不做额外脏树预检——git 自身会拒绝会覆盖本地改动的 merge。冲突不做特殊
  处理：merge 失败弹 stderr；成功但有冲突时现有 merge 组照常展示。
- **Remove**：`Dialog.confirm`（destructive；detail 明示"分支保留"）→
  `git worktree remove`。脏目录失败 → `Dialog.error` 带 stderr（提示去
  终端 `--force` 或先清理）；成功 → 强制刷新 + `onGitActivity`。
  v1 不提供 UI 强删、不顺带删分支。

在该 worktree 中已开着的 terminal tab 不动（shell 照常存活，用户自行关闭）。

## 6. 错误与边界

- 名字不合法（空、`/`、分支非法字符）在弹框层拦截，不发 git。
- 分支已存在 / 目录已占用 → git 原生错误直达用户（换名重试）。
- bare repo 的 cwd：`rev-parse --show-toplevel` 失败 → 按非 git 处理。
- 远程 space：同一 `ScmTransport.run(host:)`，引号处理现成；Open 在该远程
  workspace 开 tab，cwd 为远程绝对路径。
- 所有写操作走 `ScmStore` 串行队列；完成后 `invalidate(root:)` 刷新面板
  状态、Files 树徽章、侧栏分支行（现有机制）。
- repo root 无父目录等病态情形不特判，交给 git 失败并展示。

## 7. 测试（`run-tests.sh` 无头体系）

- Core 纯函数：
  - `WorktreePlan.target`：常规、root 尾斜杠、多级路径。
  - `WorktreePlan.validateName`：各非法输入逐一拒绝，合法名放行。
  - `WorktreeList.parse`：主 + linked + detached + bare fixtures。
  - 带哨兵的 transport payload 解析（status + worktrees 两段）。
  - `WorktreeOp.commands()` argv 快照。
- UI seam（`Dialog.presenterOverride` 注入 prompt）：
  - `+` 点击在 git / 非 git / nil-dir 三分支的行为。
  - 创建流程：成功开新 tab 于目标路径；失败弹 error 不开 tab。
  - 面板 Worktrees 组渲染、verbs 存在性与禁用条件。
- 布局回归断言不变（本设计不触碰区域约束）。

## 8. 非目标（v1 明确不做）

prune UI、worktree 重命名、UI 强制删除（`--force`）、Remove 时删分支、
worktree lock、detached 创建选项、跨 workspace Open。

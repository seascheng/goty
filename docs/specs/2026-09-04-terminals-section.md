# Terminals 顶层区 —— 与目录无关的终端工作区

日期:2026-09-04
状态:已确认(brainstorming 定稿)

## 问题

侧栏的 SPACES 按目录分组 tabs,分组随 pane 的 live cwd 动态重算(terminal
`cd` 后 tab 挪组)。两个痛点:

1. 与目录无关的终端工作(临时 shell、系统事务)没有安放处——不知挂哪个 space;
2. 现有三个建 tab 入口(⌘T、全局"+"、目录组"+")都隐含"某个目录"。

## 决策

新增与 SPACES **同级**的顶层区 **Terminals**:每 server(Local / 每个
ssh workspace)一份,标题常驻(空态只有标题行,无折叠)。区内是"自由终端"
——不参与目录分组,pane 的 live cwd 只喂右侧 file 面板与 git 徽章。

**明确不做**:space 下 terminal 的目录锚定。SPACES 保持动态 cwd 分组
(零改动、零迁移):组里看到的目录永远名副其实,不会"挂羊头卖狗肉"。

### 数据模型

`TabState` 新增:

```swift
/// 自由终端:属于顶层 Terminals 区,不参与目录分组。
/// pane 的 live cwd 只喂右侧 file 面板与 git 徽章。
var freeTerminal: Bool = false
```

decode 缺省 false → 旧 state.json 零迁移。split(⌘D)继承该标记。

### 侧栏布局

```
SERVERS
  Local / ssh 列表
──────────────
Terminals            ← 新顶层区(选中 server 的自由终端)
  [tab]…  "+"(仅 New Terminal)
──────────────
SPACES
  /Users/…/goty
    [tab]…  "+"(现状:Terminal / agents / worktree)
```

- `SpaceGrouping` 管线前置一步:先摘出 `freeTerminal` tabs 给 Terminals
  区,其余走现有动态分组。
- 区头复用 SPACES 的 `emphasized` 标题样式;v1 无折叠箭头。
- Tab 行渲染(标题、OSC、time-ago、状态徽章)复用现有 SidebarRowView。

### 入口语义

| 入口 | 行为 |
|---|---|
| ⌘T / 菜单 New Tab | 建自由终端(落 Terminals 区;pane 初始 cwd 按现状默认) |
| Terminals 区"+" | 同上,菜单仅 New Terminal |
| SPACES 标题"+" | New Space… 面板(下) |
| 目录组"+" | 现状不动 |
| `@tty` / `@omp` / `@ai` | 现状不动:在触发 pane 的 live cwd 建 space tab |
| 拖拽 | 目录组 tab 拖入 Terminals 区 → 置 freeTerminal;拖出 → 清除。区内排序照旧;跨区拖拽同样走现有 reorder 管线 |

### New Space… 面板

点 SPACES"+"弹出:路径输入框 + 确认。

- **Local**:输入对 ~ 展开与已访问目录补全;"浏览…"按钮 → NSOpenPanel。
- **远程**:纯输入;确认后走现有 ssh exec 通道 `test -d` 校验,目录不存在
  红字提示,不建 tab。
- 确认 → `newTab(cwd:)`(现状 API):目录组已存在则并入,否则成新组。

### 联动(全部现状)

- 右侧 file 面板跟聚焦 pane 的 live cwd,与 tab 所在区无关。
- git 徽章:Terminals 区 tab 跟 pane live cwd(cd 进 repo 显示分支);
  SPACES 组头/行现状。
- @ai 执行目标、agent 检测读 pane live cwd,不受区归属影响。

### 边界

- 远程 server 断连:Terminals 区与 SPACES 同款连接态提示。
- 删除 tab 的 runtime 清理走现有路径(freeTerminal 只是 TabState 字段,
  不引入新 runtime 键)。
- Terminals 区的 tab 关闭按钮、重命名、颜色/图标标记与 SPACES tab 同权。

## 测试(layouttest)

- free tab 不进目录组(SpaceGrouping 摘离)
- ⌘T/协调器 API 建出的 tab 带 freeTerminal
- 拖拽置/清标记(模拟 drop)
- 旧 state 解码缺省 false
- New Space 的 cwd 建 tab 落对应组;远程不存在目录不建

## 非目标(v1)

- 远程路径补全
- Terminals 区折叠
- SPACES 动态分组的锚定化

# libghostty 二开集成:主题/配置解析的坑与正解

给所有"以 libghostty dylib 为终端引擎自建 GUI"的项目(goty 是参考实现)。
以下每一条都是实测踩出来的,附验证方法。

## 背景:库构建没有应用运行时

我们用 `zig build -Dapp-runtime=none` 产出独立 dylib(patches/ 见构建)。
这个构建:

- **不内嵌主题**(strings 扫 dylib 找不到任何主题名);
- **没有 app runtime 的资源目录发现逻辑**,一切依赖 `GHOSTTY_RESOURCES_DIR`
  环境变量(`src/os/resourcesdir.zig`:release 构建 release 读该变量,
  否则交给 app runtime —— 我们没有)。

后果:用户配置里 `theme = Arthur` 能否生效,完全取决于进程能否找到
主题文件目录。**从 Ghostty 终端里启动的进程会继承该变量(碰巧能用),
Finder 双击 / iTerm2 / launchd 启动则没有 —— 同一个 binary 表现出
"谁启动的对、别人启动的不对"**。这是最迷惑人的现象,先查这里。

## 铁律:setenv 必须在 ghostty_init 之前

libghostty 在 `ghostty_init()` 时**捕获**资源目录,之后改环境变量无效:

```swift
// 正确顺序
setenv("GHOSTTY_RESOURCES_DIR", ownHome, 1)   // 先
guard ghostty_init(0, nil) == 0 else { ... }  // 后
```

实测对照(app 内诊断,GOTY_DUMP_VIEWS=1 门控):

- init 之后 setenv → `background` 解析为 `40,44,52`(#282C34,内置默认深色);
- init 之前 setenv → `28,28,28`(#1C1C1C,Arthur 正确值)。

`#282C34` 是"主题没解析成功"的指纹 —— 用户报"配色不对"时先想到它。

## 推荐布局:自管 ghostty home

不要依赖任何外部位置(用户装的 Ghostty.app 也别依赖),自己维护一份:

```
~/Library/Application Support/<你的app>/ghostty/
├── config     # 首次启动从用户现有 ghostty 配置复制一份,此后归 app 所有
└── themes/    # 首次启动从本机 Ghostty.app 引导(或随包发布)
```

- 启动时:目录缺失则引导复制 → `setenv` 指向它 → `ghostty_init`
  → `Ghostty.App(configPath: 自己的 config)`。
- 用户改主题/配色 = 直接编辑这份 config,与宿主 Ghostty、与启动方式
  全部解耦,也不用重新构建。

## config 加载链与"读不到主题色"的原因

vendored `Config.loadConfig` 的顺序(必须完整,缺一步主题就不解析):

```
ghostty_config_new
  → ghostty_config_load_file(cfg, path)   # 或 load_default_files
  → ghostty_config_load_cli_args
  → ghostty_config_load_recursive_files
  → ghostty_config_finalize               # 主题在这里才展开!
```

**`ghostty_config_get` 只暴露显式键**:配置里只写 `theme = X` 时,
`ghostty_config_get("background")` 拿不到 X 的颜色(对 GUI chrome
取色需要自己解析主题文件 —— `themes/X` 就是 `key = #hex` 的纯文本,
goty 的 `ChromeTheme.themeFileColors` 是现成实现)。

## 验证工具(抄走即用)

**最小解析探针** —— 不启动 GUI,直接问 dylib(编译时链同一个 dylib):

```swift
setenv("GHOSTTY_RESOURCES_DIR", dir, 1)
ghostty_init(0, nil)
let cfg = ghostty_config_new()
ghostty_config_load_file(cfg, configPath)     // + cli_args/recursive
ghostty_config_finalize(cfg)
var c = ghostty_config_color_s()
ghostty_config_get(cfg, &c, "background", 9)  // → 主题色? 还是 #282C34?
```

用它 A/B:换不同 resources 目录 / 删掉环境变量,一分钟定位解析问题。

**app 内诊断** —— env 门控打印,生产无害:

```swift
var probe = ghostty_config_color_s()
let ok = ghostty_config_get(app.config.config, &probe, "background", 9)
print("bg resolved=\(ok) rgb=\(probe.r),\(probe.g),\(probe.b) "
    + "env=\(ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"] ?? "nil")")
```

## 症状速查

| 症状 | 根因 |
|---|---|
| 配色是默认深色(#282C34 系),非所配主题 | 环境变量缺失,或 setenv 晚于 ghostty_init |
| "从 Ghostty 里启动正常,双击/iTerm 不对" | 继承 vs 不继承 GHOSTTY_RESOURCES_DIR |
| 启动即崩,栈在 ghostty_config_new | ghostty_init 没调(或晚于 config 创建) |
| config_get 拿不到背景/前景色 | 正常:theme 派生值不暴露,自己解析主题文件 |
| 改了主题没生效 | finalize 没调,或改错了文件(确认 app 实际读的是哪份 config) |

## goty 的对应代码

- 启动顺序与环境:`Sources/UI/AppDelegate.swift` `applicationDidFinishLaunching` 开头
- chrome 主题解析(含主题文件解析、hex 解析):`Sources/UI/Chrome.swift`
- libghostty 构建补丁:`patches/`(见 README)

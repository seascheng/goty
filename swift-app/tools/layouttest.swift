// layouttest.swift — headless layout regression harness.
//
// Instantiates the real AppWindowController offscreen, forces layout,
// and asserts the region map is non-degenerate and non-overlapping —
// including through region toggles and a heavy terminal overlay (the
// exact class of bug that collapsed the window on 2026-08-22).
//
// Built and run by run-tests.sh; NOT part of the app binary.

import AppKit
@testable import goty

@main
enum LayoutTest {
    static func main() { run() }
}
func run() {
    var failures = 0
    func check(_ cond: Bool, _ name: String) {
        if cond { print("  ok  \(name)") } else { failures += 1; print("FAIL  \(name)") }
    }

        // — AITaskCard: markdown flows INLINE (selectable label) —
        do {
            let card = AITaskCard(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
            card.renderForTest(markdown: "## head\n\nbody **bold** text\n\n- one\n- two\n")
            card.layoutSubtreeIfNeeded()
            check(card.isTextViewSelectableForTest, "AI markdown renders as a selectable inline field")
            if let field = card.selectableFieldForTest {
                // The width cap must actually bind: without
                // translatesAutoresizingMaskIntoConstraints=false the ≤ constraint is
                // ignored and the label lays out at intrinsic width,
                // clipping every line (the ellipsis report).
                check(field.bounds.width <= card.bounds.width - 12,
                      "inline text caps at card width (field \(Int(field.bounds.width)) vs card \(Int(card.bounds.width)))")
                let p = card.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), from: field)
                let hit = card.hitTest(p)
                let chain = hit.map { String(describing: type(of: $0)) } ?? "nil"
                check(chain.contains("Field"), "hit-test reaches the text field (got \(chain))")
            }
        }

        // — Sidebar SERVERS fold: chevron hides the rows, not the header —
        do {
            let sidebar = SidebarView()
            let servers = [
                WorkspaceState(id: UUID(), name: "Local", tabs: [], focusedTabIndex: 0, sshHost: nil),
                WorkspaceState(id: UUID(), name: "box", tabs: [], focusedTabIndex: 0, sshHost: "box"),
            ]
            sidebar.renderWorkspaces(servers, focusedIndex: 0)
            check(sidebar.wsRowsForTest.count == 2, "SERVERS lists both workspaces")
            check(sidebar.wsRowsForTest.allSatisfy { !$0.isHidden }, "rows visible while expanded")
            var fired: Bool?
            sidebar.onServersExpandChange = { fired = $0 }
            sidebar.setServersExpanded(false)
            check(sidebar.wsRowsForTest.allSatisfy { $0.isHidden }, "fold hides every server row")
            check(!sidebar.wsHeaderForTest.isHidden, "fold keeps the SERVERS header")
            check(fired == false, "fold reports the expansion change")
            sidebar.setServersExpanded(true)
            check(sidebar.wsRowsForTest.allSatisfy { !$0.isHidden }, "expand restores the rows")
            // A data pass under a fold rebuilds rows — they must stay hidden.
            sidebar.setServersExpanded(false)
            sidebar.renderWorkspaces(servers, focusedIndex: 0)
            check(sidebar.wsRowsForTest.allSatisfy { $0.isHidden }, "rebuilt rows honor the fold")
        }
        // — Sidebar per-space fold: one directory section folds alone —
        do {
            let sidebar = SidebarView()
            func spaceTab(_ id: String, _ cwd: String) -> TabState {
                TabState(id: id, name: id, panes: [PaneState(id: "p-\(id)", cwd: cwd)])
            }
            var ws = WorkspaceState(id: UUID(), name: "local",
                tabs: [spaceTab("a", "/tmp/fold-a"), spaceTab("b", "/tmp/fold-a"),
                       spaceTab("c", "/tmp/fold-b")],
                focusedTabIndex: 0, sshHost: nil)
            sidebar.render(workspace: ws)
            check(sidebar.tabsRowsForTest.count == 3, "two spaces render three rows")
            check(sidebar.tabsRowsForTest.allSatisfy { !$0.isHidden }, "rows visible while expanded")
            var fired: [String]?
            sidebar.onSpaceFoldsChange = { fired = $0 }
            sidebar.toggleSpaceFold("/tmp/fold-a")
            check(fired == ["/tmp/fold-a"], "fold reports the folded space")
            check(sidebar.spaceHeaderExpandedForTest("/tmp/fold-a") == false
                  && sidebar.spaceHeaderExpandedForTest("/tmp/fold-b") == true,
                  "fold flips its own chevron, not the other section's")
            check(sidebar.tabsRowsForTest[0].isHidden && sidebar.tabsRowsForTest[1].isHidden,
                  "fold hides only its own section's rows")
            check(!sidebar.tabsRowsForTest[2].isHidden, "other space's rows stay visible")
            check(sidebar.tabsVisibleForTest.count == 4,
                  "visible = other rows + both headers + its gap")
            // A new tab in the folded space re-renders — it must land hidden.
            // Section regrouping puts d INSIDE fold-a: row order a, b, d, c.
            ws.tabs.append(spaceTab("d", "/tmp/fold-a"))
            sidebar.render(workspace: ws)
            let rows = sidebar.tabsRowsForTest
            check(rows.count == 4 && rows[0].isHidden && rows[1].isHidden
                  && rows[2].isHidden && !rows[3].isHidden,
                  "rebuilt rows honor the fold (new tab included)")
            // Fold BOTH sections (fold-a still folded): the spacing
            // tiles must stay — a folded header keeps its distance from
            // the section above.
            sidebar.toggleSpaceFold("/tmp/fold-b")
            check(sidebar.tabsVisibleForTest.count == 3,
                  "folded sections keep their spacing tiles (2 headers + 1 gap)")
            sidebar.toggleSpaceFold("/tmp/fold-a")
            check(sidebar.spaceHeaderExpandedForTest("/tmp/fold-a") == true,
                  "expand flips the chevron back")
            sidebar.toggleSpaceFold("/tmp/fold-b")
            check(sidebar.tabsRowsForTest.allSatisfy { !$0.isHidden }, "expand restores every row")
        }
    let d = UserDefaults.standard
    d.set(false, forKey: "sidebarCollapsed")
    d.set(200.0, forKey: "sidebarWidth")
    d.set(true, forKey: "rightPanelVisible")
    d.set(260.0, forKey: "rightPanelWidth")
    // Uncaught-NSException detail (headless crashes print bare "Abort").
    NSSetUncaughtExceptionHandler { e in
        FileHandle.standardError.write(
            "UNCAUGHT \(e.name.rawValue): \(e.reason ?? "?")\n\(e.callStackSymbols.prefix(8).joined(separator: "\n"))\n"
                .data(using: .utf8)!)
    }

    _ = NSApplication.shared   // AppKit machinery; we never run() it.
    let wc = AppWindowController()
    let window = wc.window
    // Off-screen FROM BIRTH, before anything can order in over it:
    // every later show(over: window) centers HERE, so no test window
    // ever appears on the user's screen (the "test run keeps opening
    // an ssh hosts window" report — parking after show() left a
    // real on-screen flash and a straggler if the binary wedges).
    window.setFrameOrigin(NSPoint(x: 30000, y: 30000))
    let content = window.contentView!
    content.layoutSubtreeIfNeeded()

    func frames() -> (sidebar: CGRect, terminal: CGRect, panel: CGRect, content: CGRect) {
        content.layoutSubtreeIfNeeded()
        return (wc.sidebar.frame, wc.terminalArea.frame, wc.rightPanel.frame, content.bounds)
    }

    print("— chrome theme contrast —")
    let aizen = ChromeTheme(background: NSColor(hex: "#f0f2f6")!,
                            foreground: NSColor(hex: "#4a4d66")!, accent: .gray)
    check(ChromeTheme.contrastRatio(aizen.secondaryText, aizen.background) >= 4.4,
          "light-theme secondaryText ≥≈4.5:1")
    check(ChromeTheme.contrastRatio(aizen.tertiaryText, aizen.background) >= 3.4,
          "light-theme tertiaryText ≥≈3.5:1")
    check(aizen.hoverFill != aizen.foreground,
          "light-theme hover is a wash, not the foreground (black-hover bug)")
    let pale = ChromeTheme(background: NSColor(hex: "#f0f2f6")!,
                           foreground: NSColor(hex: "#9fd8ac")!, accent: .gray)
    check(ChromeTheme.contrastRatio(pale.legibleForeground(), pale.background) >= 4.4,
          "pale foreground floored to ≥≈4.5:1")
    let dark = ChromeTheme(background: NSColor(hex: "#1c1c1c")!,
                           foreground: NSColor(hex: "#ddeedd")!, accent: .gray)
    check(ChromeTheme.contrastRatio(dark.secondaryText, dark.background) >= 4.5,
          "dark-theme secondaryText keeps the design step (≥4.5:1, not the bare 3:1 floor)")
    check(ChromeTheme.contrastRatio(dark.hoverFill, dark.background) >= 1.1,
          "dark-theme hover lifted")

    print("— region map —")
    var f = frames()
    check(f.content.width > 1000 && f.content.height > 600, "content substantial")
    check(f.sidebar.width >= 180 && f.sidebar.width <= 460, "sidebar clamped width (\(f.sidebar.width))")
    wc.setSidebarWidth(120)
    f = frames()
    check(f.sidebar.width >= 225, "sidebar min 225 enforced (\(f.sidebar.width))")
    wc.setSidebarWidth(600)
    f = frames()
    check(f.sidebar.width <= 460, "sidebar max 460 enforced (\(f.sidebar.width))")
    wc.setSidebarWidth(240)
    f = frames()
    check(f.terminal.width > 400, "terminal region wide (\(f.terminal.width))")
    check(f.panel.width >= 216, "right panel ≥ min width (\(f.panel.width))")
    check(f.sidebar.maxX <= f.terminal.minX + 0.5, "sidebar|terminal no overlap")
    check(f.terminal.maxX <= f.panel.minX + 0.5, "terminal|panel no overlap")
    check(abs(f.sidebar.height + 30 - f.content.height) < 0.5, "sidebar fills below the titlebar")
    // The strip moved INSIDE the terminal region: full height outside,
    // pane grid offset 32 inside (full-bleed overlays cover the strip).
    // Unflipped coords: the top offset reads as bounds.maxY - frame.maxY.
    check(abs(f.terminal.height + 30 - f.content.height) < 0.5, "terminal fills below the titlebar")
    let grid = wc.terminalArea.paneGrid
    check(abs((wc.terminalArea.bounds.height - grid.frame.maxY)) < 0.5,
          "expanded: pane grid flush to region top (no strip)")
    // Titlebar band: full-width top band; regions start below it.
    let tb = wc.titlebar
    check(tb.superview === content, "titlebar is IN the view tree")
    wc.setChromeTitle("Goty — probe-workspace")
    content.layoutSubtreeIfNeeded()
    let tl = wc.titlebar.titleLabelFrameForProbe
    check(tl.width > 40 && tl.height > 10,
          "title label has real size (got \(tl))")
    check(abs((content.bounds.height - tb.frame.maxY)) < 0.5 && tb.frame.height == 30,
          "titlebar spans the window top (\(tb.frame))")
    check(abs(f.sidebar.maxY - f.content.height + tb.frame.height) < 0.5,
          "sidebar starts below the titlebar")
    check(abs(f.panel.height + 30 - f.content.height) < 0.5, "panel fills below the titlebar")

    print("— right panel collapse/expand round trip —")
    let terminalWidthBefore = f.terminal.width
    wc.toggleRightPanel()
    f = frames()
    check(wc.rightPanel.isHidden, "collapsed hides panel")
    check(f.terminal.width > terminalWidthBefore, "terminal reclaims width (\(f.terminal.width))")
    wc.toggleRightPanel()
    f = frames()
    check(abs(f.terminal.width - terminalWidthBefore) < 0.5, "expand restores terminal width")
    check(f.panel.width >= 216, "panel width restored")

    // Titlebar band multi-click (2026-08-25 rapid-click fix): the system
    // titlebar container claims clickCount ≥ 2 above content; GotyWindow
    // re-dispatches them to the hit IconButton. The titlebar's right
    // toggle is the target now (the in-panel tile is gone).
    print("— titlebar band: multi-click re-dispatch —")
    let toggleBtn = wc.titlebar.rightToggle
    let bandP = wc.titlebar.convert(
        NSPoint(x: toggleBtn.frame.midX, y: toggleBtn.frame.midY), to: nil)
    func bandEvent(_ count: Int) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: bandP, modifierFlags: [],
                           timestamp: 0, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
    }
    window.sendEvent(bandEvent(3))
    check(AppPreferences.shared.rightPanelVisible == false,
          "clickCount=3 on the titlebar toggle collapses the panel")
    window.sendEvent(bandEvent(4))
    check(AppPreferences.shared.rightPanelVisible == true,
          "clickCount=4 toggles it back")

    print("— sidebar collapse/expand round trip (rail + top strip) —")
    wc.toggleSidebar()
    f = frames()
    check(!wc.sidebar.isHidden, "collapsed keeps the rail visible")
    check(abs(f.sidebar.width - SidebarView.railWidth) < 0.5,
          "rail width (\(f.sidebar.width))")
    check(f.terminal.minX > 40, "terminal starts after the rail (\(f.terminal.minX))")
    check(!wc.terminalArea.tabStrip.isHidden, "collapsed shows the tab strip")
    check(abs((wc.terminalArea.bounds.height
               - wc.terminalArea.paneGrid.frame.maxY) - 28) < 0.5,
          "collapsed: pane grid starts 28pt below the strip")
    check(abs(f.sidebar.height + wc.titlebar.frame.height - f.content.height) < 0.5,
          "rail runs below the titlebar")
    wc.toggleSidebar()
    f = frames()
    check(f.terminal.minX >= 180, "expand restores sidebar width (\(f.terminal.minX))")
    check(wc.terminalArea.tabStrip.isHidden, "expand hides the tab strip")

    print("— servers '+' host picker —")
    // 2026-08-23 regression: host items carried no representedObject, so
    // clicking a server in the picker did nothing. Fire every item
    // through the real target/action path and assert the wiring. The
    // manual-entry item became "Manage Hosts…" — the ~/.ssh/config
    // manager REPLACED the prompt that deadlocked inside the menu
    // tracking session.
    var addedHosts: [String] = []
    wc.sidebar.onAddWorkspace = { addedHosts.append($0) }
    var openedManager = false
    wc.sidebar.onManageSSHConfig = { openedManager = true }
    let picker = wc.sidebar.hostPickerEntries(hosts: ["alpha", "beta"])
    check(picker.count == 3 && picker[2] == .manage,
          "picker = hosts + manage entry (\(picker.count) entries)")
    for entry in picker {
        wc.sidebar.fireHostPicker(entry)
    }
    check(addedHosts == ["alpha", "beta"],
          "host entries fire onAddWorkspace (\(addedHosts))")
    check(openedManager, "manage entry opens the SSH config manager")


    print("— SSH config document (Core, pure) —")
    // The manager's whole contract: parse ~/.ssh/config, edit
    // surgically, keep everything else byte-identical.
    let sample = """
    # work machines
    Host alpha beta
      HostName 10.0.0.1
      User alice
      Port 2222
      # tunnel
      ProxyJump jump

    Host *.internal
      User bob

    Match host gamma
      User carol

    Host delta
      HostName delta.example.com
    """
    var doc = SSHConfigDocument(text: sample)
    check(doc.rendered == sample, "unedited document round-trips byte-identical")
    check(doc.stanzas.count == 3, "Host stanzas parsed; Match block is not one (\(doc.stanzas.count))")
    check(doc.stanzas[0].aliases == ["alpha", "beta"] && doc.stanzas[0].hostName == "10.0.0.1"
          && doc.stanzas[0].user == "alice" && doc.stanzas[0].port == "2222",
          "stanza fields parse (alias list, HostName, User, Port)")
    check(doc.inventoryAliases == ["alpha", "beta", "delta"],
          "inventory: order preserved, wildcards excluded (\(doc.inventoryAliases))")

    // Edit: rename the alias, move HostName, clear Port — foreign lines stay.
    check((try? doc.updateHost(0, aliases: ["alpha2"], hostName: "10.9.9.9",
                               user: "alice", port: nil)) != nil, "valid edit passes validation")
    let afterEdit = doc.rendered
    check(afterEdit.contains("Host alpha2") && afterEdit.contains("  HostName 10.9.9.9"),
          "edit rewrites the Host line and HostName")
    check(!afterEdit.contains("2222"), "cleared Port drops its line")
    check(afterEdit.contains("  # tunnel") && afterEdit.contains("  ProxyJump jump"),
          "comments and unknown keywords inside the stanza survive")
    check(afterEdit.contains("Match host gamma") && afterEdit.contains("  User carol"),
          "Match block untouched by the edit above it")
    let reparsed = SSHConfigDocument(text: afterEdit)
    check(reparsed.stanzas[0].aliases == ["alpha2"] && reparsed.stanzas[0].port == nil,
          "edited stanza reparses to the new values")

    // Add: appended with a blank separator; prefix untouched.
    check((try? doc.addHost(aliases: ["epsilon"], hostName: "eps.example.com",
                            user: nil, port: "22")) != nil, "valid add passes validation")
    check(doc.rendered.hasPrefix(afterEdit), "add never disturbs existing content")
    check(doc.rendered.contains("\nHost epsilon\n  HostName eps.example.com\n  Port 22"),
          "add appends a full stanza")

    // Remove: the stanza's lines go; the Match block STAYS (Match closes
    // the stanza above it — the range bug that once ate it).
    doc.removeHost(0)
    check(!doc.rendered.contains("alpha2") && !doc.rendered.contains("ProxyJump"),
          "remove deletes the stanza's lines")
    check(doc.rendered.contains("Match host gamma") && doc.rendered.contains("  User carol")
          && doc.rendered.contains("Host *.internal"),
          "Match block and neighboring stanzas survive the remove")

    // Validation rejects BEFORE mutating.
    var strict = SSHConfigDocument(text: sample)
    check((try? strict.addHost(aliases: [], hostName: nil, user: nil, port: nil)) == nil,
          "empty alias list rejected")
    check((try? strict.addHost(aliases: ["-x"], hostName: nil, user: nil, port: nil)) == nil,
          "option-looking alias rejected")
    check((try? strict.updateHost(0, aliases: ["alpha"], hostName: nil, user: nil, port: "abc")) == nil,
          "non-numeric port rejected")
    check(strict.rendered == sample, "rejected edits leave the document unchanged")

    print("— SSH config store (file I/O) —")
    func perms(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions]
            as? NSNumber)?.intValue ?? -1
    }
    let storeDir = NSTemporaryDirectory() + "/sshcfg-test-" + UUID().uuidString
    let store = SSHConfigStore(url: URL(fileURLWithPath: storeDir + "/.ssh/config"))
    check(store.load().stanzas.isEmpty, "missing file loads as an empty document")
    var fresh = SSHConfigDocument(text: "")
    try? fresh.addHost(aliases: ["newbox"], hostName: "new.example.com", user: "dana", port: "2200")
    check((try? store.save(fresh)) != nil, "save creates the .ssh path and config file")
    check(perms(storeDir + "/.ssh") == 0o700 && perms(store.url.path) == 0o600,
          "ssh perms enforced (dir \(String(perms(storeDir + "/.ssh"), radix: 8)), "
          + "file \(String(perms(store.url.path), radix: 8)))")
    let loaded = store.load().stanzas.first
    check(loaded?.aliases == ["newbox"] && loaded?.hostName == "new.example.com"
          && loaded?.user == "dana" && loaded?.port == "2200",
          "save→load round trip keeps the stanza")

    print("— SSH config manager window —")
    // A STANDALONE window: left host list, right editor form. Nothing
    // is presented in the main window (user request 2026-08-23 — the
    // manager must not live in the main UI).
    let controller = SSHConfigWindowController(store: store)
    let manager = controller.manager
    check(controller.window.contentView === manager,
          "manager view owns the standalone window's content")
    // NEVER order this window: no test may put a window on the user's
    // screen (the recurring "test run pops an ssh hosts window"
    // reports — off-screen parking still flashed). Unshown + parked,
    // the view tree and every CRUD path below run identically.
    controller.window.setFrameOrigin(NSPoint(x: 30000, y: 30000))
    controller.window.contentView?.layoutSubtreeIfNeeded()
    check(!wc.terminalArea.isShowingOverlay,
          "manager presents NO overlay in the main window")

    // Left-right structure: list column left, editor right, disjoint.
    controller.window.contentView?.layoutSubtreeIfNeeded()
    let listFrame = manager.listColumnFrameForTest
    let editorFrame = manager.editorFrameForTest
    check(listFrame.width > 100 && editorFrame.width > 150
          && listFrame.maxX <= editorFrame.minX + 0.5,
          "left list column, right editor pane, disjoint "
          + "(list \(listFrame.width), editor \(editorFrame.width))")
    check(manager.hostRowCountForTest == 1, "one row per stanza on open")

    // Select → editor prefilled from the stanza.
    manager.selectForTest(0)
    check(manager.editorForTest.fieldTextForTest.alias == "newbox",
          "selecting a host loads its fields into the form")
    manager.editorForTest.typeForTest(.init(alias: "newbox", hostName: "moved.example.com",
                                            user: "dana", port: ""))
    manager.editorForTest.commitForTest()
    let edited = store.load().stanzas.first
    check(edited?.hostName == "moved.example.com" && edited?.port == nil,
          "commit writes HostName and clears Port")

    // Add: '+' → empty form → commit lands in file and list.
    manager.beginAddForTest()
    check(manager.editorForTest.fieldTextForTest.alias.isEmpty,
          "add starts from an empty form")
    manager.editorForTest.typeForTest(.init(alias: "gui-box", hostName: "gui.example.com",
                                            user: "", port: "2022"))
    manager.editorForTest.commitForTest()
    check(manager.hostRowCountForTest == 2,
          "committed add lists the host")
    check(store.load().stanzas.contains { $0.aliases == ["gui-box"] },
          "add reached the file")

    // Invalid commit: dialog acknowledged via the seam, form stays.
    Dialog.presenterOverride = { _, _ in nil }
    manager.beginAddForTest()
    manager.editorForTest.typeForTest(.init(alias: "   ", hostName: "", user: "", port: ""))
    manager.editorForTest.commitForTest()
    check(manager.hostRowCountForTest == 2
          && store.load().stanzas.count == 2,
          "invalid add keeps the form open and writes nothing")
    Dialog.presenterOverride = nil
    manager.cancelEditingForTest()

    // Cancel is dismiss: an EXISTING host's Cancel also drops the
    // selection (the dead-button report) and buttons are uniform.
    manager.selectForTest(0)
    check(manager.hasSelectionForTest, "host selected before cancel")
    manager.cancelEditingForTest()
    check(!manager.hasSelectionForTest && manager.hostRowCountForTest == 2,
          "cancel on an existing host deselects, keeps the list")
    controller.window.contentView?.layoutSubtreeIfNeeded()
    let editorButtons = manager.editorForTest.subviews.flatMap { $0.subviews }
        .compactMap { $0 as? ChromeButton }
    check(editorButtons.count == 2,
          "editor has Save + Cancel (\(editorButtons.count))")
    check(editorButtons.allSatisfy { abs($0.frame.height - ControlMetrics.buttonHeight) < 0.5 }
          && editorButtons.allSatisfy { $0.frame.width >= ControlMetrics.buttonMinWidth - 0.5 },
          "both buttons: system height and min width (the size-mismatch report)")

    // Delete the selected host.
    manager.selectForTest(1)
    manager.deleteSelectedForTest()
    check(manager.hostRowCountForTest == 1
          && !store.load().stanzas.contains { $0.aliases == ["gui-box"] },
          "delete removes the selected host and saves")
    try? FileManager.default.removeItem(atPath: storeDir)
    print("— server status page —")
    // A just-added server shows the status page (spinner, no button) as
    // an overlay over the terminal region; the unreachable phase keeps
    // the Reconnect button.
    let connecting = ServerStatusView(wsName: "box", phase: .connecting) {}
    wc.terminalArea.presentOverlay(connecting, kind: .offline)
    content.layoutSubtreeIfNeeded()
    check(connecting.frame.width > 300 && connecting.frame.height > 300,
          "status page covers terminal region (\(connecting.frame.width)x\(connecting.frame.height))")
    let spinners = connecting.subviews.compactMap { $0 as? NSProgressIndicator }
    check(spinners.count == 1 && spinners[0].style == .spinning,
          "connecting phase shows one spinner")
    check(connecting.subviews.allSatisfy { !($0 is ClosureButton) },
          "connecting phase has no reconnect button")
    let unreachable = ServerStatusView(wsName: "box", phase: .unreachable) {}
    let buttons = unreachable.subviews.compactMap { $0 as? ClosureButton }
    check(buttons.count == 1 && buttons[0].title == "Reconnect",
          "unreachable phase keeps the reconnect button")
    let titles = unreachable.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
    check(titles.contains { $0.contains("unreachable") },
          "unreachable title present")
    wc.terminalArea.dismissOverlay(kind: .offline)

    print("— tab title priority (ghostty rule) —")
    // userTitle wins over the program's OSC title; unset falls back to
    // the program title. Rename must also survive the title churn that
    // once tore the edit field down mid-typing.
    let ws = WorkspaceState(
        id: UUID(), name: "local",
        tabs: [
            TabState(id: "a", name: "1", panes: [PaneState(id: "p1", cwd: nil)]),
            TabState(id: "b", name: "2", userTitle: "mine",
                     panes: [PaneState(id: "p2", cwd: nil)]),
        ],
        focusedTabIndex: 0, sshHost: nil)
    func tabRow(_ i: Int) -> SidebarRowView? {
        func walk(_ v: NSView) -> [SidebarRowView] {
            v.subviews.compactMap { $0 as? SidebarRowView } + v.subviews.flatMap(walk)
        }
        return walk(wc.sidebar).first { $0.tabIndex == i }
    }
    wc.sidebar.render(workspace: ws, titleFor: { _ in "osc-title" })
    content.layoutSubtreeIfNeeded()
    check(tabRow(0)?.displayText == "osc-title",
          "no user title → program title shows")
    check(tabRow(1)?.displayText == "mine",
          "user title outranks program title")

    let rowBefore = tabRow(0)
    wc.sidebar.beginRename(index: 0)
    check(tabRow(0)?.isRenaming == true, "beginRename opens the field")
    wc.sidebar.render(workspace: ws, titleFor: { _ in "osc-title-2" })
    check(tabRow(0) === rowBefore && tabRow(0)?.isRenaming == true,
          "renaming row survives a title-churn re-render")
    check(tabRow(0)?.displayText == "osc-title",
          "skipped pass keeps the editing row's label")

    var committed: [String] = []
    wc.sidebar.onRenameTabTo = { _, name in committed.append(name) }
    let field = tabRow(0)?.subviews.compactMap { $0 as? RenameField }.first
    field?.stringValue = "renamed"
    tabRow(0)?.endInlineRename(commit: true)
    check(committed == ["renamed"], "commit sends the new name")
    wc.sidebar.beginRename(index: 0)
    tabRow(0)?.subviews.compactMap { $0 as? RenameField }.first?.stringValue = ""
    tabRow(0)?.endInlineRename(commit: true)
    check(committed == ["renamed", ""], "empty commit clears the override")
    // After the editing ends, renders flow again and honor the model.
    var ws2 = ws
    ws2.tabs[0].userTitle = "renamed"
    wc.sidebar.render(workspace: ws2, titleFor: { _ in "osc-title-3" })
    check(tabRow(0)?.displayText == "renamed" && !(tabRow(0)?.isRenaming ?? false),
          "post-commit render shows the user title")

    print("— row reuse: identity survives volatile re-renders —")
    // The 2026-08-24 hover flicker: volatile fields (OSC title, the
    // spinner char riding it) change the render signature at agent
    // cadence; the old teardown recreated every row per pass, dropping
    // hover state and re-firing mouseEntered under a still cursor.
    // Rows are now reused in place — the VIEW OBJECTS must survive
    // content churn, a section move, and closure retargeting.
    let t1 = TabState(id: "ru1", name: "1", panes: [PaneState(id: "rp1", cwd: nil)])
    let t2 = TabState(id: "ru2", name: "2", panes: [PaneState(id: "rp2", cwd: nil)])
    var ruWs = WorkspaceState(id: UUID(), name: "local", tabs: [t1, t2],
                              focusedTabIndex: 0, sshHost: nil)
    wc.sidebar.render(workspace: ruWs)
    content.layoutSubtreeIfNeeded()
    let ruFirst = tabRow(0), ruSecond = tabRow(1)

    // Spinner-char churn alone (⠋ → ⠸) forces a signature change.
    wc.sidebar.render(workspace: ruWs,
                      statusFor: { _ in SpaceStatus(activity: .working, seen: true, spinner: "⠋") },
                      commandFor: { _ in "omp" },
                      titleFor: { _ in "t" })
    wc.sidebar.render(workspace: ruWs,
                      statusFor: { _ in SpaceStatus(activity: .working, seen: true, spinner: "⠸") },
                      commandFor: { _ in "omp" },
                      titleFor: { _ in "t" })
    content.layoutSubtreeIfNeeded()
    check(tabRow(0) === ruFirst && tabRow(1) === ruSecond,
          "rows survive title/spinner churn as the same view objects")
    let churnBadge = tabRow(1)?.subviews.compactMap { $0 as? SidebarRowView.SpaceStatusView }.first
    let churnField = churnBadge?.subviews.compactMap { $0 as? NSTextField }.first
    check(churnField?.stringValue == "⠸",
          "spinner char updates in place (\(churnField?.stringValue ?? "nil"))")

    // A cwd arriving moves tab 2 into its own section — same views,
    // new arrangement (header now between them).
    ruWs.tabs[1].panes[0].cwd = "/elsewhere"
    wc.sidebar.render(workspace: ruWs)
    content.layoutSubtreeIfNeeded()
    check(tabRow(0) === ruFirst && tabRow(1) === ruSecond,
          "rows survive a section move without recreation")
    let gap = (tabRow(1)?.frame.minY ?? 0) - (tabRow(0)?.frame.minY ?? 0)
    check(gap > 44, "moved row lands below the new section header (Δ=\(gap))")

    // Closed tab: its row leaves the stack; the survivor retargets.
    ruWs.tabs.remove(at: 0)
    ruWs.focusedTabIndex = 0
    wc.sidebar.render(workspace: ruWs)
    content.layoutSubtreeIfNeeded()
    check(tabRow(0) === ruSecond && tabRow(1) == nil,
          "closed tab's row is gone; survivor retargets to index 0")

    // Selection state→style mapping (2026-08-25 stuck-gray fix): a
    // reused row deselected by configure() must drop its selection
    // pill IMMEDIATELY — not wait for the next hover event to
    // opportunistically repaint (the old bug left the previous tab's
    // gray pill on screen after selecting another tab).
    ruWs.tabs = [t1, t2]
    ruWs.focusedTabIndex = 0
    wc.sidebar.render(workspace: ruWs)
    content.layoutSubtreeIfNeeded()
    let selRow0 = tabRow(0), selRow1 = tabRow(1)
    check(selRow0?.selectionPaintedForTest == true && selRow1?.selectionPaintedForTest == false,
          "tab 0 selected: exactly one row carries the pill")
    ruWs.focusedTabIndex = 1
    wc.sidebar.render(workspace: ruWs)
    content.layoutSubtreeIfNeeded()
    check(selRow1?.selectionPaintedForTest == true,
          "tab 1 now selected (same view object)")
    check(selRow0?.selectionPaintedForTest == false,
          "tab 0 deselected: pill cleared without waiting for a hover")
    check(selRow0 === tabRow(0) && selRow1 === tabRow(1),
          "selection flip reuses both row views")

    print("— server close modes: remove vs close —")
    // Mode 1 (Remove Server…) keeps the sessions on the server and
    // removes the entry; mode 2 (Close Server…) terminates them; offline
    // rows get Reconnect plus the same non-destructive Remove.
    let wsOn = WorkspaceState(id: UUID(), name: "srv-x", tabs: [],
                              focusedTabIndex: 0, sshHost: "srv-x")
    let wsOff = WorkspaceState(id: UUID(), name: "srv-off", tabs: [],
                               focusedTabIndex: 0, sshHost: "srv-off")
    wc.sidebar.renderWorkspaces([wsOn, wsOff], focusedIndex: 0,
                                states: [wsOn.id: .connected, wsOff.id: .disconnected])
    func wsRow(_ label: String) -> SidebarRowView? {
        func walk(_ v: NSView) -> [SidebarRowView] {
            v.subviews.compactMap { $0 as? SidebarRowView } + v.subviews.flatMap(walk)
        }
        return walk(wc.sidebar).first { $0.tabIndex == nil && $0.displayText == label }
    }
    let onMenu = wsRow("srv-x")?.serverMenu()
    let onTitles = onMenu?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? []
    check(onTitles == ["Remove Server…", "Close Server…"],
          "online server offers both close modes (\(onTitles))")

    let offMenu = wsRow("srv-off")?.serverMenu()
    let offTitles = offMenu?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? []
    check(offTitles == ["Reconnect", "Remove Server…"],
          "offline server offers reconnect + remove (\(offTitles))")

    var disconnectedIdx: [Int] = []
    var closedIdx: [(Int, Bool)] = []
    wc.sidebar.onDisconnectWorkspace = { disconnectedIdx.append($0) }
    wc.sidebar.onDeleteWorkspace = { closedIdx.append(($0, $1)) }

    for item in onMenu?.items ?? [] where item is ActionMenuItem {
        _ = NSApp.sendAction(item.action!, to: item.target, from: item)
    }
    check(disconnectedIdx == [0] && closedIdx.count == 1 && closedIdx[0].0 == 0 && closedIdx[0].1,
          "both items fire their mode (\(disconnectedIdx) \(closedIdx))")

    print("— collapsed rail: servers as status dots —")
    func all<T: NSView>(_ type: T.Type, in v: NSView) -> [T] {
        let direct = (v as? T).map { [$0] } ?? []
        return direct + v.subviews.flatMap { all(type, in: $0) }
    }
    let rail = all(ServerRailButton.self, in: wc.sidebar)
    check(rail.count == 2, "one rail dot per server (\(rail.count))")
    check(rail[0].dotFill == Chrome.theme.wsConnected, "connected dot is green")
    check(rail[1].dotFill == Chrome.theme.wsDisconnected, "offline dot is red")
    check(rail[0].toolTip == "srv-x — Connected", "tooltip carries name + state")
    var railSelected: [Int] = []
    wc.sidebar.onWorkspaceSelected = { railSelected.append($0) }
    rail[1].mouseDown(with: NSEvent())
    check(railSelected == [1], "rail dot selects its server (\(railSelected))")
    content.layoutSubtreeIfNeeded()
    // 2026-08-23: the server dot had no width pin — the leading floor
    // let it stretch text→trailing on short labels.
    let wsDot = wsRow("srv-x")?.subviews.compactMap { $0 as? SidebarRowView.DotView }.first
    check(wsDot != nil && abs(wsDot!.frame.width - 6) < 0.5,
          "server dot pinned at 6pt (\(wsDot?.frame.width ?? -1))")

    print("— top tab strip: chips mirror the tab list —")
    wc.terminalArea.tabStrip.render(workspace: ws2, offline: false,
                                    titleFor: { _ in "osc-title-3" })
    content.layoutSubtreeIfNeeded()
    let chips = all(TabChipView.self, in: wc.terminalArea)
    check(chips.count == 2, "one chip per tab (\(chips.count))")
    check(chips[0].displayText == "renamed" && chips[1].displayText == "mine",
          "chips show the resolved titles (\(chips.map(\.displayText)))")
    var stripSelected: [Int] = []
    wc.terminalArea.tabStrip.onTabSelected = { stripSelected.append($0) }
    chips[1].mouseDown(with: NSEvent())
    check(stripSelected == [1], "chip click selects its tab (\(stripSelected))")
    var stripClosed: [Int] = []
    wc.terminalArea.tabStrip.onCloseTab = { stripClosed.append($0) }
    chips[0].subviews.compactMap { $0 as? IconButton }.first?.onClick?()
    check(stripClosed == [0], "chip close button closes its tab (\(stripClosed))")

    // Ghostty tab math: chips share the visible bar EQUALLY, floored at
    // minTabWidth; past the floor the row runs past the clip and the
    // scroll view takes over (the native titlebar-tab layout).
    let strip = wc.terminalArea.tabStrip
    let clip = strip.subviews.compactMap { $0 as? NSScrollView }.first?.contentView
    let clipW = clip?.bounds.width ?? 0
    check(clipW > 400, "strip clip has real width (\(clipW))")
    let w0 = chips[0].frame.width, w1 = chips[1].frame.width
    check(abs(w0 - w1) < 1.5, "two chips equal width (\(w0) vs \(w1))")
    // separators (1pt + 2pt spacing) sit between chips; the share is
    // of what remains after them.
    check(w0 > 200 && w0 < clipW, "chips share the bar (share=\(w0), clip=\(clipW))")
    check(w0 >= TabStripView.minTabWidth - 0.5, "chips at or above the floor")

    // Overflow: enough tabs to blow past the floor → every chip pins at
    // min width and the row is wider than the clip (scrollable).
    var manyWs = ws2
    manyWs.tabs = (0..<14).map {
        TabState(id: "m\($0)", name: "\($0)", panes: [PaneState(id: "mp\($0)", cwd: nil)])
    }
    manyWs.focusedTabIndex = 0
    strip.render(workspace: manyWs, offline: false)
    content.layoutSubtreeIfNeeded()
    let manyChips = all(TabChipView.self, in: wc.terminalArea)
    check(manyChips.allSatisfy { abs($0.frame.width - TabStripView.minTabWidth) < 1.5 },
          "overflow pins every chip at the min width (\(manyChips.map { Int($0.frame.width) }))")
    let rowWidth = (manyChips.last?.frame.maxX ?? 0) - (manyChips.first?.frame.minX ?? 0)
    check(rowWidth > clipW,
          "overflow row runs past the clip (\(rowWidth) > \(clipW))")

    // The "window only grows" regression: with the strip overflowing
    // (row wider than the clip), the chip row's width must NOT leak
    // into the window's autolayout minimum — the scroll view absorbs
    // it, and the window must still accept a smaller legal size.
    let originalSize = window.frame.size
    window.setContentSize(NSSize(width: 1000, height: 600))
    content.layoutSubtreeIfNeeded()
    check(window.frame.width <= 1000.5,
          "window shrinks below the chip row's width (w=\(window.frame.width))")
    window.setContentSize(originalSize)
    content.layoutSubtreeIfNeeded()

    print("— replay sanitizer strips historical queries —")
    // 2026-08-23: every reattached pane showed garbage after the first
    // prompt — the replayed ring re-fed the prompt theme's DA/DECRQM/
    // XTWINOPS/OSC probes, the fresh core answered them again, and the
    // replies landed in the PTY as typed input.
    let esc = "\u{1b}"
    let replay = "➜  goty git:(main) ✗ "
        + esc + "[>c" + esc + "[?2026$p" + esc + "[>c" + esc + "[?2048$p"
        + esc + "[16t" + esc + "[18t" + esc + "]10;?\u{7}"
        + esc + "[1;32m" + "ok" + esc + "[0m" + esc + "[2J" + esc + "[4;10;20t"
        + esc + "]0;set-title\u{7}" + esc + "]11;#101010\u{7}"
    let cleaned = ReplaySanitizer().stripQueries(from: replay.data(using: .utf8)!)
    let s = String(decoding: cleaned, as: UTF8.self)
    check(!s.contains("$p") && !s.contains(">c") && !s.contains("[16t")
          && !s.contains("[18t") && !s.contains("10;?"),
          "historical queries stripped (\(s.debugDescription))")
    check(s.contains("➜  goty git:(main) ✗ ")
          && s.contains(esc + "[1;32mok" + esc + "[0m")
          && s.contains(esc + "[2J") && s.contains(esc + "[4;10;20t")
          && s.contains("]0;set-title") && s.contains("]11;#101010"),
          "text, SGR, clear, non-query t, title and color SETS preserved")
    // A trailing incomplete sequence is preserved when replay finishes.
    let tail = Data([0x1b, UInt8(ascii: "["), UInt8(ascii: "3")])
    let tailSanitizer = ReplaySanitizer()
    check(tailSanitizer.stripQueries(from: tail).isEmpty
          && tailSanitizer.finish() == tail,
          "truncated CSI at end of replay kept")
    check(ReplaySanitizer().stripQueries(from: (esc + "[c" + esc + "[>0c" + "x").data(using: .utf8)!)
          == Data("x".utf8),
          "DA1/DA2 queries removed, following text intact")
    // A resize can divide one terminal query between replay segments.
    // Sanitizing each SNAPSHOT independently preserves both halves; the
    // fresh core joins them again and writes the size report into the PTY.
    let splitQueryChunks = [
        Data((esc + "[18").utf8),
        Data(("t" + esc + "[14").utf8),
        Data("tvisible".utf8),
    ]
    let splitSanitizer = ReplaySanitizer()
    let independentlyCleaned = splitQueryChunks.reduce(into: Data()) {
        $0.append(splitSanitizer.stripQueries(from: $1))
    }
    check(independentlyCleaned == Data("visible".utf8),
          "queries split across replay snapshots are removed")
    // DECSET 2048 is not a query and must remain in the rendered replay,
    // but parsing it synchronously emits a size report. PaneHost suppresses
    // parser writes for that replay-only interval instead of deleting state.
    let modeSet = Data((esc + "[?2048hvisible").utf8)
    check(ReplaySanitizer().stripQueries(from: modeSet) == modeSet,
          "mode 2048 state survives replay sanitization")
    check(PaneHost.shouldForwardParserWrite(isReplaying: true) == false
          && PaneHost.shouldForwardParserWrite(isReplaying: false),
          "parser replies are suppressed only during replay")
    let replayFrames = [SessionOutputKind.size, SessionOutputKind.snapshot,
                        SessionOutputKind.output, SessionOutputKind.size,
                        SessionOutputKind.attached, SessionOutputKind.output]
    check(PaneHost.parserWriteStates(for: replayFrames)
          == [false, false, false, false, false, true],
          "write gate covers snapshots, replay output and replay resizes")

    print("— space rows: agent-style badge + branch-only meta —")
    let badge = SidebarRowView.SpaceStatusView()
    badge.status = SpaceStatus(activity: .working, seen: true, spinner: "⣿")
    let badgeField = badge.subviews.compactMap { $0 as? NSTextField }.first
    check(badgeField?.stringValue == "⣿" && badgeField?.isHidden == false,
          "working badge shows the title's braille spinner")
    badge.status = SpaceStatus(activity: .idle, seen: false, spinner: nil)
    check(badgeField?.isHidden == true && badge.stateWord == "done",
          "done badge swaps spinner for a symbol")
    badge.status = SpaceStatus(activity: .blocked, seen: true, spinner: nil)
    check(badge.stateWord == "blocked", "blocked badge names itself")

    // A repo space renders branch-only on the second line; the old
    // "+2 −1" counts are gone.
    let repoTab = TabState(id: "r1", name: "1", panes: [PaneState(id: "rp", cwd: "/repo")])
    let repoWs = WorkspaceState(id: UUID(), name: "local", tabs: [repoTab],
                                focusedTabIndex: 0, sshHost: nil)
    wc.sidebar.render(workspace: repoWs,
                      gitFor: { _ in GitSummary(branch: "gpui-upgrade", added: 3, removed: 1) })
    content.layoutSubtreeIfNeeded()
    check(tabRow(0)?.metaText == "gpui-upgrade",
          "second line is the branch only (\(tabRow(0)?.metaText ?? "nil"))")

    // omp/pi status comes from their in-process extension reporting to
    // the owning sessiond (see sessiond/src/extension_asset.ts) — no
    // passive manifest; the wire strings map onto AgentActivity.
    check(AgentDetect.hasRules(for: "omp") == false, "omp rides the extension, not manifests")
    check(AgentActivity("working") == .working && AgentActivity("blocked") == .blocked
          && AgentActivity("idle") == .idle && AgentActivity("bogus") == nil,
          "extension wire strings map to activities")

    // The badge and the hover-revealed close button share the right
    // column: at REST the badge sits in it (aligned with the dot
    // column, −8); on HOVER the badge steps aside — the close button
    // takes the tail, so the two never compete for the same pixels.
    wc.sidebar.render(workspace: repoWs,
                      gitFor: { _ in GitSummary(branch: "gpui-upgrade", added: 0, removed: 0) },
                      statusFor: { _ in SpaceStatus(activity: .working, seen: true, spinner: "⣿") },
                      commandFor: { _ in "omp" })
    content.layoutSubtreeIfNeeded()
    let rowBadge = tabRow(0)?.subviews.compactMap { $0 as? SidebarRowView.SpaceStatusView }.first
    let rowClose = tabRow(0)?.subviews.compactMap { $0 as? IconButton }.first
    check(rowBadge?.isHidden == false, "working space shows its badge")
    if let row = tabRow(0), let rowBadge, let rowClose {
        check(rowBadge.frame.maxX == row.bounds.maxX - 8,
              "badge rides the right column at −8 (maxX=\(rowBadge.frame.maxX), row=\(row.bounds.maxX))")
        row.mouseEntered(with: bandEvent(1))
        check(rowClose.isHidden == false && rowBadge.isHidden == true,
              "hover: close button takes the tail, badge steps aside")
        row.mouseExited(with: bandEvent(1))
        check(rowBadge.isHidden == false,
              "leaving hover restores the badge")
    }

    print("— heavy terminal overlay must not move regions —")
    // The 2026-08-22 disaster, distilled: a leaf feature view full of
    // constrained children, presented over the terminal region. Regions
    // must not move by a single point.
    let overlay = NSView()
    overlay.translatesAutoresizingMaskIntoConstraints = false
    for i in 0..<80 {
        let b = NSButton(title: "b\(i)", target: nil, action: nil)
        b.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(b)
        b.leadingAnchor.constraint(equalTo: overlay.leadingAnchor).isActive = true
        b.topAnchor.constraint(equalTo: overlay.topAnchor, constant: CGFloat(i * 4)).isActive = true
        b.widthAnchor.constraint(equalToConstant: 90).isActive = true
        b.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }
    let before = frames()
    wc.terminalArea.presentOverlay(overlay)
    f = frames()
    check(abs(f.sidebar.width - before.sidebar.width) < 0.5
          && abs(f.panel.width - before.panel.width) < 0.5
          && abs(f.terminal.width - before.terminal.width) < 0.5,
          "regions unchanged while overlay presented")
    check(overlay.frame.width > 400, "overlay got real width (\(overlay.frame.width))")

    // The REAL editor, presented the way AppDelegate presents it: the
    // exact configuration that once collapsed the window. Regions must
    // not move; dismiss must restore.
    print("— real editor overlay —")
    let editor = EditorPanelView()
    editor.onVisibilityChange = { visible in
        if visible {
            wc.terminalArea.presentOverlay(editor, fullBleed: true)
        } else if wc.terminalArea.isShowingOverlay {
            wc.terminalArea.dismissOverlay()
        }
    }
    let beforeEditor = frames()
    editor.show()
    f = frames()
    check(abs(f.sidebar.width - beforeEditor.sidebar.width) < 0.5
          && abs(f.panel.width - beforeEditor.panel.width) < 0.5
          && abs(f.terminal.width - beforeEditor.terminal.width) < 0.5,
          "regions unchanged with editor presented")
    // fullBleed: the editor's top IS the region's top — no titlebar-height
    // margin above its header (user request 2026-08-22).
    check(editor.frame.minY < 0.5 && editor.frame.width > 400 && editor.frame.height > 400,
          "editor flush to top, real frame (\(editor.frame.width)x\(editor.frame.height))")
    // The PREVIEW path (user-reported crash): open a real markdown file,
    // flip preview on — render + engine + scroll swap — inside the
    // presented overlay, then hide. The fixture is written locally: a
    // hardcoded repo path died with a project rename, and
    // the open failure surfaced as a REAL modal error dialog that
    // wedged the headless run.
    let mdFixture = NSTemporaryDirectory() + "layouttest-\(UUID().uuidString).md"
    try? """
    # title
    paragraph one with enough text to lay out glyphs.
    ```swift
    let x = 1
    ```
    """.write(toFile: mdFixture, atomically: true, encoding: .utf8)
    editor.open(path: mdFixture, source: LocalFileSource())
    for _ in 0..<40 {   // drain main queue: 40 × 50ms cap
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    // The window-can't-shrink-with-editor-open report: the status
    // bar's labels demanded their full text width, raising the window's
    // autolayout minimum to 1147pt the moment a file opened. The two
    // user-visible symptoms, encoded directly: (1) a small window
    // stays small with the editor open, (2) it still accepts an even
    // smaller legal size — paths/names truncate instead of demanding
    // their full text width.
    window.setContentSize(NSSize(width: 900, height: 600))
    content.layoutSubtreeIfNeeded()
    check(abs(window.frame.width - 900) < 0.5,
          "small window with editor open stays small (\(window.frame.width))")
    window.setContentSize(NSSize(width: 700, height: 460))
    content.layoutSubtreeIfNeeded()
    check(window.frame.width <= 700.5,
          "editor open: window shrinks to a small size (\(window.frame.width))")
    window.setContentSize(NSSize(width: 1280, height: 800))
    content.layoutSubtreeIfNeeded()

    // The webview body: the page must come up (ready) and the opened
    // file's content must round-trip through the bridge INTO the page
    // (getText reads the live CodeMirror doc — layout-level proof the
    // load pipeline works, the webview-era replacement for the old
    // glyph-count assertions).
    let pageReady = { () -> Bool in
        for _ in 0..<400 {   // 400 × 50ms = 20s for the bundle to boot
            if editor.pageReadyForTest { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return editor.pageReadyForTest
    }()
    if !pageReady {
        var diag = ""
        var gotDiag = false
        editor.webViewForTest.evaluateJavaScript(
            "document.readyState + '/' + document.body.innerHTML.length") { r, e in
            diag = "readyState=\(r ?? "nil") err=\(e.map { "\($0)" } ?? "none")"
                + " isLoading=\(editor.webViewForTest.isLoading)"
                + " url=\(editor.webViewForTest.url?.absoluteString ?? "nil")"
            gotDiag = true
        }
        for _ in 0..<40 {
            if gotDiag { break }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        print("     page diag: \(diag)")
    }
    check(pageReady, "editor page posted ready")
    if pageReady {
        for _ in 0..<40 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        var pageText: String?
        var got = false
        editor.webViewForTest.evaluateJavaScript(
            "window.__goty.getText()") { r, _ in
            pageText = r as? String
            got = true
        }
        for _ in 0..<100 {
            if got { break }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        let fixtureText = (try? String(contentsOfFile: mdFixture, encoding: .utf8)) ?? ""
        check(got && pageText == fixtureText,
              "file content landed in the page (\(pageText?.count ?? 0) vs \(fixtureText.count) chars)")
        check(editor.bridgeDeliveredForTest > 0, "bridge delivered document events")
        // Zoom: a page-dispatched ⌘= must reach Swift (zoomFont) and
        // the new size must come back as the page's --app-font.
        let before = AppPreferences.shared.editorFontSize
        editor.webViewForTest.evaluateJavaScript(
            "document.dispatchEvent(new KeyboardEvent('keydown', " +
            "{key: '=', metaKey: true, code: 'Equal', bubbles: true, cancelable: true})); 'ok'") { _, _ in }
        for _ in 0..<60 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        check(AppPreferences.shared.editorFontSize > before,
              "zoom key reached Swift (\(before) → \(AppPreferences.shared.editorFontSize))")
    }
    editor.togglePreview()
    content.layoutSubtreeIfNeeded()
    check(editor.findBarEnabledForTest, "search armed (page Mod-F)")

    // 2026-08-22's real root cause, locked in: the renderer once put an
    // NSColor into a .font slot (ordered-list marker). AppKit's
    // attribute fixer then throws inside any layout pass. Render a doc
    // covering every construct — ordered lists included — and assert
    // every .font value IS an NSFont.
    let constructs = """
    # h
    **b** *i* ~~s~~ `c` [l](https://x.y)
    - bullet
    1. ordered
    10. ordered2
    - [ ] task

    > quote

    | a | b |
    |---|---|
    | 1 | 2 |

    ```swift
    let x = 1
    ```
    """
    let rendered = MarkdownRenderer.render(constructs, bodySize: 12.5, highlight: nil)
    var badFonts = 0
    rendered.enumerateAttribute(.font, in: NSRange(location: 0, length: rendered.length)) { v, _, _ in
        if !(v is NSFont) { badFonts += 1 }
    }
    check(badFonts == 0 && rendered.length > 50,
          "renderer .font slots are all NSFont (bad=\(badFonts), len=\(rendered.length))")

    // Block decorations the preview view paints: code + quote marked as
    // ranges (view fills geometry edge-to-edge), tables carry real
    // NSTextTableBlocks (TextKit's table layout, not text-run columns).
    var codeMarked = 0, quoteMarked = 0, tableBlocks = 0
    rendered.enumerateAttribute(.mdCodeBlock, in: NSRange(location: 0, length: rendered.length)) { v, r, _ in
        if v != nil { codeMarked += r.length }
    }
    rendered.enumerateAttribute(.mdQuote, in: NSRange(location: 0, length: rendered.length)) { v, r, _ in
        if v != nil { quoteMarked += r.length }
    }
    rendered.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: rendered.length)) { v, _, _ in
        if let ps = v as? NSParagraphStyle, !ps.textBlocks.isEmpty { tableBlocks += ps.textBlocks.count }
    }
    check(codeMarked >= "let x = 1".count,
          "code block marked for full-width background (\(codeMarked) chars)")
    check(quoteMarked >= "quote".count,
          "quote marked for bar decoration (\(quoteMarked) chars)")
    check(tableBlocks >= 4,
          "table renders as NSTextTable blocks (\(tableBlocks) blocks)")

    // Vertical rhythm + list hanging indent, MEASURED from a real
    // layout pass (the 2026-08-24 report: paragraphs ran at the font's
    // own height with zero block gap, and list continuation lines never
    // indented — the style sat on a marker tail, not the paragraph).
    let rhythmDoc = "first paragraph\n\nsecond paragraph\n\n- item text long enough to wrap onto a second line inside the narrow measurement container\n- item two follows"
    let rhythmText = MarkdownRenderer.render(rhythmDoc, bodySize: 14, highlight: nil)
    var psChars = 0
    rhythmText.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: rhythmText.length)) { v, r, _ in
        if v != nil { psChars += r.length }
    }
    let rStorage = NSTextStorage(attributedString: rhythmText)
    let rManager = NSLayoutManager()
    rStorage.addLayoutManager(rManager)
    let rContainer = NSTextContainer(size: NSSize(width: 240, height: CGFloat.greatestFiniteMagnitude))
    rContainer.lineFragmentPadding = 0
    rManager.addTextContainer(rContainer)
    let rGlyphs = rManager.glyphRange(forBoundingRect:
        NSRect(x: 0, y: 0, width: 240, height: 10000), in: rContainer)
    // USED rects carry the geometry that matters: paragraph spacing
    // shows as distance between fragments (lineFragmentRect folds it
    // into the preceding fragment's height), indents shift used minX.
    var frags: [NSRect] = []
    var g = rGlyphs.location
    while g < NSMaxRange(rGlyphs) {
        var effective = NSRange()
        let fr = rManager.lineFragmentUsedRect(forGlyphAt: g, effectiveRange: &effective,
                                               withoutAdditionalLayout: true)
        frags.append(fr)
        g = NSMaxRange(effective)
    }
    // >=4 lines: para1, para2, item line1, item line2 (wrapped).
    check(frags.count >= 4, "rhythm doc laid out \(frags.count) lines")
    if frags.count >= 4 {
        let paraGap = frags[1].minY - frags[0].maxY
        check(paraGap >= 5,
              "paragraph gap comes from spacing (\(String(format: "%.1f", paraGap))pt)")
        let itemFirst = frags[2]
        let wrapped = frags[3...].first { $0.minY > itemFirst.maxY }
        check(wrapped != nil && wrapped!.minX >= itemFirst.minX + 8,
              "list continuation hangs past the marker (first=\(itemFirst.minX), " +
              "wrapped=\(wrapped?.minX ?? -1))")
        // Between items: the item gap only — a second "\n" (the inner
        // paragraph's terminator + the item's own) used to leave a
        // full blank line between every pair (report 2026-08-24).
        if let last = frags.last, let prev = frags.dropLast().last {
            let interItem = last.minY - prev.maxY
            check(interItem < 12,
                  "no blank line between items (\(String(format: "%.1f", interItem))pt)")
        }
    }

    // Diff document (Git tab row click): a real repo fixture, a staged
    // change, the patch flows into the page like any document.
    let repo = NSTemporaryDirectory() + "layouttest-diff-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
    _ = Shell.exec("cd '\(repo)' && /usr/bin/git init -q && "
                   + "/usr/bin/git config user.email t@t && /usr/bin/git config user.name t")
    try? "line one\nline two\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
    _ = Shell.exec("cd '\(repo)' && /usr/bin/git add a.txt")
    let patch = ScmStore.shared.diff(root: repo, host: nil, path: "a.txt",
                                     staged: true, untracked: false)
    check(patch?.contains("+line one") == true && patch?.contains("new file") == true,
          "ScmStore.diff produces a staged patch")
    editor.openDiff(root: repo, host: nil, path: "a.txt", staged: true,
                    untracked: false, source: LocalFileSource())
    for _ in 0..<40 {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    check(editor.editorTextForTest.contains("+line one"),
          "diff document loaded into the model")
    if editor.pageReadyForTest {
        var diffText = ""
        var gotDiff = false
        editor.webViewForTest.evaluateJavaScript(
            "window.__goty.getText()") { r, _ in
            diffText = r as? String ?? ""
            gotDiff = true
        }
        for _ in 0..<100 {
            if gotDiff { break }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        check(gotDiff && diffText.contains("+line one"),
              "diff patch landed in the page")
    }
    check(editor.diffSplitForTest, "diff defaults to split view")
    try? FileManager.default.removeItem(atPath: repo)
    editor.hide()
    f = frames()
    check(abs(f.terminal.width - beforeEditor.terminal.width) < 0.5,
          "editor dismiss restores region")

    print("— worktree model (Core, pure) —")
    // WorktreePlan.target: beside the REPO root, name appended after it.
    check(WorktreePlan.target(root: "/Users/x/code/goty", name: "fix-login")
          == "/Users/x/code/goty-fix-login",
          "target lands beside the repo root")
    check(WorktreePlan.target(root: "/Users/x/code/goty/", name: "x")
          == "/Users/x/code/goty-x", "trailing slash normalized")
    check(WorktreePlan.target(root: "/deep/nest/repo", name: "n")
          == "/deep/nest/repo-n", "deep roots keep their parent")
    // validateName: branch-name rules ("/" is also the prompt's own rule).
    check(WorktreePlan.validateName("fix-login") == nil, "plain name valid")
    check(WorktreePlan.validateName("feat_2.x") == nil, "dotted name valid")
    check(WorktreePlan.validateName("") != nil, "empty rejected")
    check(WorktreePlan.validateName("   ") != nil, "whitespace-only rejected")
    check(WorktreePlan.validateName("-x") != nil, "leading dash rejected")
    check(WorktreePlan.validateName("..") != nil, "'..' rejected")
    check(WorktreePlan.validateName("a/b") != nil, "'/' rejected")
    check(WorktreePlan.validateName("a b") != nil, "space rejected")
    check(WorktreePlan.validateName("a~b") != nil && WorktreePlan.validateName("a:b") != nil
          && WorktreePlan.validateName("a?b") != nil && WorktreePlan.validateName("a*b") != nil
          && WorktreePlan.validateName("a[b") != nil && WorktreePlan.validateName("a\\b") != nil,
          "special branch characters rejected")
    check(WorktreePlan.validateName("x.lock") != nil, "'.lock' suffix rejected")
    // WorktreeList.parse: porcelain fixtures (main + linked + detached).
    let porcelain = """
    worktree /Users/x/code/goty
    HEAD abc123
    branch refs/heads/main

    worktree /Users/x/code/goty-fix-login
    HEAD def456
    branch refs/heads/fix-login

    worktree /Users/x/code/goty-hotfix
    HEAD 789abc
    detached

    """
    let parsed = WorktreeList.parse(porcelain)
    check(parsed.count == 3, "three records parse")
    check(parsed[0].isMain && parsed[0].branch == "main"
          && parsed[0].path == "/Users/x/code/goty",
          "main record: isMain + short branch")
    check(parsed[1].branch == "fix-login" && !parsed[1].isMain,
          "linked record: short branch, not main")
    check(parsed[2].detached && parsed[2].branch == nil,
          "detached record: no branch")
    let bare = WorktreeList.parse("worktree /srv/git/repo.git\nbare\n\n")
    check(bare.count == 1 && bare[0].bare && bare[0].isMain, "bare record parses")
    // WorktreeOp argv snapshots.
    check(WorktreeOp.create(path: "/x/repo-fix", branch: "fix").commands()
          == [["worktree", "add", "-b", "fix", "/x/repo-fix"]], "create argv")
    check(WorktreeOp.merge(branch: "fix").commands()
          == [["merge", "--no-edit", "fix"]], "merge argv")
    check(WorktreeOp.remove(path: "/x/repo-fix").commands()
          == [["worktree", "remove", "/x/repo-fix"]], "remove argv")
    // Transport payload: the sentinel shape feeds worktrees; the legacy
    // shape still parses (worktrees empty).
    let payload = "/Users/x/code/goty\n\u{1F}"
        + "# branch.oid (initial)\u{0}? new.txt\u{0}\u{1F}" + porcelain
    let fromTransport = ScmStore.parseTransport(payload)
    check(fromTransport?.root == "/Users/x/code/goty"
          && fromTransport?.worktrees.count == 3
          && fromTransport?.untracked.count == 1,
          "three-section payload: status + worktrees in one parse")
    let legacy = ScmStore.parseTransport("/Users/x/code/goty\n? new.txt\u{0}")
    check(legacy != nil && legacy?.worktrees.isEmpty == true,
          "pre-worktree payload: status parses, worktrees empty")

    print("— worktree card: live preview + gated create —")
    let wtCard = WorktreeCard(root: "/Users/x/code/goty")
    wtCard.frame = NSRect(x: 0, y: 0, width: WorktreeCard.cardWidth, height: 300)
    content.layoutSubtreeIfNeeded()
    check(wtCard.previewTextForTest == "/Users/x/code/goty-"
          && !wtCard.createEnabledForTest,
          "empty name: bare preview, create disabled")
    wtCard.typeNameForTest("fix-login")
    check(wtCard.previewTextForTest == "/Users/x/code/goty-fix-login"
          && wtCard.createEnabledForTest && wtCard.validationTextForTest == nil,
          "valid name: full target preview, create enabled")
    wtCard.typeNameForTest("a/b")
    check(!wtCard.createEnabledForTest && wtCard.validationTextForTest?.contains("/") == true,
          "slash name: inline reason, create disabled")
    wtCard.typeNameForTest("-x")
    check(!wtCard.createEnabledForTest, "leading dash rejected inline")
    wtCard.typeNameForTest("ok-name")
    var created: [String] = []
    wtCard.onCreate = { created.append($0) }
    wtCard.commit()
    check(created == ["ok-name"], "Return/Create commits the validated name")
    wtCard.typeNameForTest("bad/name")
    wtCard.commit()

    print("— worktree window (SSH-manager recipe, non-modal) —")
    // The card presents in its OWN titled window — no runModal, so
    // none of the menu-tracking modal traps. Headless pins: the
    // presenter seam short-circuits, and the window recipe matches
    // the SSH manager (hidden system title, card below the light band).
    var seamRoots: [String] = []
    WorktreeWindow.presenterOverride = { root in
        seamRoots.append(root)
        return "seam-name"
    }
    var createdViaSeam: [String] = []
    WorktreeWindow.present(root: "/tmp/repo", over: nil) {
        createdViaSeam.append($0)
    }
    WorktreeWindow.presenterOverride = nil
    check(seamRoots == ["/tmp/repo"] && createdViaSeam == ["seam-name"],
          "presenter seam answers without a window")
    let wwc = WorktreeWindowController(root: "/tmp/repo") { _ in }
    // Unshown + parked — same no-window-on-screen rule as the SSH
    // manager above; the property checks need no ordering.
    wwc.window.setFrameOrigin(NSPoint(x: 30000, y: 30000))
    check(wwc.window.titleVisibility == .hidden
          && wwc.window.contentView !== nil
          && !wwc.window.isReleasedWhenClosed,
          "worktree window: hidden system title, content, retained")
    wwc.close()
    WorktreeWindow.closeForTest()

    print("— one dialog system: PromptCard rides the DialogCard chassis —")
    // Dialog.present renders THROUGH PromptCard + presentCard — no
    let prompt = PromptCard(title: "Rename Tab", detail: nil, primary: "OK",
                            cancel: "Cancel", destructive: false,
                            placeholder: "tab title")
    check(prompt.input != nil,
          "prompt card: DialogCard chassis with an input")
    check(PromptCard.cardWidth == 340 && WorktreeCard.cardWidth == 480,
          "card width tiers come from the card classes, one system")
    let confirm = PromptCard(title: "Close pane?", detail: nil, primary: "Close",
                             cancel: "Cancel", destructive: true, placeholder: nil)
    check(confirm.input == nil, "confirm card: no input, buttons only")
    print("— worktree panel + flow (real temp repo) —")
    // A REAL repo on disk: the panel's Worktrees group, its verbs, and
    // coordinator.createWorktree — everything except the dialog prompt
    // (whose seam is Dialog.presenterOverride) runs the actual git.
    func runsh(_ cmd: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
    }
    func shOut(_ cmd: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(),
                      encoding: .utf8) ?? ""
    }
    var repoDir = NSTemporaryDirectory() + "wt-flow-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: repoDir,
                                             withIntermediateDirectories: true)
    runsh("cd '\(repoDir)' && git init -q -b main"
          + " && git config user.email t@t && git config user.name t"
          + " && echo hi > a.txt && git add a.txt && git commit -qm init")
    // git resolves firmlinks (/var → /private/var) that the URL APIs
    // do not — every later path comparison uses git's own answer.
    repoDir = shOut("cd '\(repoDir)' && git rev-parse --show-toplevel")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let repoName = (repoDir as NSString).lastPathComponent
    let repoParent = (repoDir as NSString).deletingLastPathComponent

    let panel = ScmPanelView()
    panel.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(panel)
    NSLayoutConstraint.activate([
        panel.leadingAnchor.constraint(equalTo: content.leadingAnchor),
        panel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        panel.topAnchor.constraint(equalTo: content.topAnchor),
        panel.heightAnchor.constraint(equalToConstant: 600),
    ])
    func rowKeys(_ v: NSView) -> [String] {
        (v.subviews.compactMap { ($0 as? KeyedRow)?.rowKey }) + v.subviews.flatMap(rowKeys)
    }
    func wtRows(_ v: NSView) -> [WorktreeRowView] {
        v.subviews.compactMap { $0 as? WorktreeRowView } + v.subviews.flatMap(wtRows)
    }
    /// Wall-clock settle: `run(mode:before:)` returns on ANY event, so
    /// a round-count budget collapses to milliseconds under event churn
    /// (the 2026-08-27 load-13 failures: 500 nominal rounds ran in
    /// ~1s). Rounds now only size the slices; the deadline is real.
    func settle(_ rounds: Int = 24) {
        let deadline = Date().addingTimeInterval(TimeInterval(rounds) * 0.05)
        while Date() < deadline {
            RunLoop.current.run(mode: .default,
                                before: Date().addingTimeInterval(0.05))
        }
    }
    panel.setTarget(cwd: repoDir, host: nil)
    settle(60)
    check(rowKeys(panel).contains("hdr:worktrees"),
          "Worktrees group header present")
    let mainRow = wtRows(panel).first { $0.rowKey == "wt:\(repoDir)" }
    check(mainRow != nil && mainRow?.buttonsForTest.count == 1,
          "main worktree row: Open only (keys=\(rowKeys(panel)), repo=\(repoDir))")

    // A linked worktree (created OUTSIDE the app — the panel lists
    // those too), a commit on MAIN, then Merge through the side row's
    // button: the row's verb acts on ITS own worktree — the focused
    // branch (main) is brought INTO side, so side fast-forwards to it.
    let sidePath = repoParent + "/" + repoName + "-side"
    runsh("cd '\(repoDir)' && git worktree add -q -b side '\(sidePath)'"
          + " && cd '\(repoDir)' && echo b > b.txt && git add b.txt && git commit -qm main-work")
    panel.refresh(force: true)
    settle(60)
    let sideRow = wtRows(panel).first { $0.rowKey == "wt:\(sidePath)" }
    check(sideRow != nil && sideRow?.buttonsForTest.count == 3,
          "linked worktree row: Open + Merge + Remove (keys=\(rowKeys(panel)), side=\(sidePath))")
    sideRow?.buttonsForTest[1].onClick?()   // Merge
    settle(90)
    func gitOut(_ cmd: String) -> String {
        shOut("cd '\(repoDir)' && " + cmd)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    check(gitOut("git rev-parse main") == gitOut("git rev-parse side"),
          "Merge fast-forwards side to main (main=\(gitOut("git rev-parse main")), side=\(gitOut("git rev-parse side")))")

    // Remove: confirm dialog auto-answered via the seam; directory
    // goes, branch stays, row disappears.
    Dialog.presenterOverride = { _, _ in "ok" }
    wtRows(panel).first { $0.rowKey == "wt:\(sidePath)" }?.buttonsForTest[2].onClick?()
    settle(90)
    Dialog.presenterOverride = nil
    check(!FileManager.default.fileExists(atPath: sidePath),
          "worktree directory removed")
    check(gitOut("git branch --list side") == "side",
          "branch kept after worktree remove (branches=\(gitOut("git branch")))")
    panel.refresh(force: true)
    settle(60)
    check(!rowKeys(panel).contains("wt:\(sidePath)"),
          "row gone after remove")

    // coordinator.createWorktree: the sidebar "+" flow's Core half —
    // resolve → `worktree add -b` → success carries the target (the
    // tab jump is appendTab, already covered by its own usage).
    let coord = WorkspaceCoordinator()   // store nil: git effects only
    var createResult: Result<String, ScmOpFailure>?
    coord.createWorktree(name: "two", cwd: repoDir, host: nil) { createResult = $0 }
    settle(90)
    let expectTarget = WorktreePlan.target(root: repoDir, name: "two")
    if case .success(let target)? = createResult {
        check(target == expectTarget,
              "create returns the target path (got=\(target), want=\(expectTarget))")
    } else {
        check(false, "createWorktree succeeds")
    }
    check(FileManager.default.fileExists(atPath: expectTarget + "/a.txt"),
          "worktree checked out beside the repo")
    check(!shOut("cd '\(repoDir)' && git rev-parse --verify two").isEmpty,
          "branch 'two' created")

    // Split geometry — the terminal right-click menu's four directions
    // (Split Right/Left/Down/Up) all land in splitCells. Pure cells,
    // pinned headless: base cell doubles, target halves, `after` picks
    // the NEW pane's half (false = left/top).
    print("— split geometry (terminal context menu's 4 directions) —")
    func cellStr(_ p: PaneState) -> String {
        "\(p.left),\(p.top) \(p.width)x\(p.height)"
    }
    func split(_ cells: [PaneState], _ target: Int, _ v: Bool, _ after: Bool)
        -> (target: String, siblings: [String], frame: String)? {
        guard let r = WorkspaceCoordinator.splitCells(
            cells, target: target, vertical: v, after: after) else { return nil }
        return (cellStr(r.cells[target]),
                r.cells.enumerated().filter { $0.offset != target }.map { cellStr($0.element) },
                "\(r.newFrame.left),\(r.newFrame.top) \(r.newFrame.width)x\(r.newFrame.height)")
    }
    var sp = split([PaneState(id: "a", cwd: nil, left: 0, top: 0, width: 2, height: 2)], 0, false, true)   // RIGHT
    check(sp?.target == "0,0 2x2" && sp?.frame == "2,0 2x2",
          "split right: target keeps left half, new pane right (got \(sp?.target ?? "-") / \(sp?.frame ?? "-"))")
    sp = split([PaneState(id: "a", cwd: nil, left: 0, top: 0, width: 2, height: 2)], 0, false, false)      // LEFT
    check(sp?.target == "2,0 2x2" && sp?.frame == "0,0 2x2",
          "split left: target keeps right half, new pane left (got \(sp?.target ?? "-") / \(sp?.frame ?? "-"))")
    sp = split([PaneState(id: "a", cwd: nil, left: 0, top: 0, width: 2, height: 2)], 0, true, true)        // DOWN
    check(sp?.target == "0,0 2x2" && sp?.frame == "0,2 2x2",
          "split down: target keeps top half, new pane below (got \(sp?.target ?? "-") / \(sp?.frame ?? "-"))")
    sp = split([PaneState(id: "a", cwd: nil, left: 0, top: 0, width: 2, height: 2)], 0, true, false)       // UP
    check(sp?.target == "0,2 2x2" && sp?.frame == "0,0 2x2",
          "split up: target keeps bottom half, new pane above (got \(sp?.target ?? "-") / \(sp?.frame ?? "-"))")
    sp = split([PaneState(id: "a", cwd: nil, left: 0, top: 0, width: 2, height: 2),
                PaneState(id: "b", cwd: nil, left: 2, top: 0, width: 2, height: 2)],
               0, true, true)
    check(sp?.siblings == ["2,0 2x4"],
          "siblings double along the split axis only (got \(sp?.siblings.joined(separator: " | ") ?? "-"))")
    check(WorkspaceCoordinator.splitCells([PaneState(id: "a", cwd: nil)], target: 5,
                                          vertical: false, after: true) == nil,
          "out-of-range target is rejected, not crashed")

    // Server remove → re-add: Mode 1 keeps sessions running on the
    // host, so the workspace's pane ids (the attach keys) must be
    // recoverable — re-adding the host restores them verbatim and
    // openPane's attach hits the still-running panes (2026-08-25
    // remove-server-orphaned-sessions bug).
    print("— server remove → re-add restores pane identity —")
    let parkURL = URL(fileURLWithPath:
        NSTemporaryDirectory() + "goty-park-\(UUID().uuidString).json")
    let pstore = WorkspaceStore(sessionName: "goty", fileURL: parkURL)
    let pcoord = WorkspaceCoordinator()
    pcoord.store = pstore
    let pwsId = UUID()
    let srvTab = TabState(id: UUID().uuidString, name: "1",
                          panes: [PaneState(id: "pane-live", cwd: "/srv")],
                          paneCommand: "claude")
    pstore.workspaces = [WorkspaceState(id: pwsId, name: "srv-a", tabs: [srvTab],
                                        focusedTabIndex: 0, sshHost: "srv-a")]
    pcoord.teardownWorkspace(pwsId, park: true)
    check(pstore.workspaces.allSatisfy { !$0.isRemote } && pstore.parked.count == 1,
          "remove parks the remote workspace instead of dropping it")
    pcoord.addWorkspace(host: "srv-a")
    let restored = pstore.workspaces.first { $0.sshHost == "srv-a" }
    check(restored?.id == pwsId && restored?.tabs.first?.panes.first?.id == "pane-live",
          "re-add restores the same workspace/pane ids (attach reattaches)")
    check(pstore.parked.isEmpty, "parked entry consumed on re-add")
    check(WorkspaceStore(sessionName: "goty", fileURL: parkURL)
            .workspaces.contains { $0.sshHost == "srv-a" },
          "restored server persists across reload")
    // Mode 2 (Close Server) kills the sessions — no parking.
    pcoord.teardownWorkspace(pwsId)
    check(!pstore.workspaces.contains { $0.sshHost == "srv-a" } && pstore.parked.isEmpty,
          "close drops the workspace for real (no zombie parked copy)")

    // Local workspace display name is derived, not stored: non-remote
    // always shows "Local" (no rename-at-load migration to rot).
    check(WorkspaceState(id: UUID(), name: "whatever", tabs: [],
                         focusedTabIndex: 0, sshHost: nil).displayName == "Local",
          "local workspace displays as Local regardless of stored name")
    check(WorkspaceState(id: UUID(), name: "srv-a", tabs: [],
                         focusedTabIndex: 0, sshHost: "srv-a").displayName == "srv-a",
          "remote keeps the host alias as display name")

    // Space identity: one git repo = one space. The resolver collapses
    // subdirs and linked worktrees onto the repo's main root; a
    // non-repo path stays its own space.
    func spaceTab(_ id: String, _ cwd: String?) -> TabState {
        TabState(id: id, name: id, panes: [PaneState(id: "p-\(id)", cwd: cwd)])
    }
    let repoSub = spaceTab("s", "/work/goty/swift-app")
    let repoWt = spaceTab("w", "/work/goty-wt2")
    let plainDir = spaceTab("p", "/tmp/notes")
    let spaceSecs = SpaceGrouping.sections(for: [repoSub, repoWt, plainDir],
                                            spaceRoot: { cwd in
        cwd.hasPrefix("/work/goty") ? "/work/goty" : nil
    })
    check(spaceSecs.count == 2 && spaceSecs[0].name == "goty"
              && spaceSecs[0].tabIndexs == [0, 1]
              && spaceSecs[1].name == "notes" && spaceSecs[1].tabIndexs == [2],
          "one git repo is one space: subdir + worktree share a section, "
              + "non-repo paths stay their own")

    // Sidebar "+" menu: built pure, fired like the host picker.
    // Flat shape: terminal + worktree + separator + one entry per ACP
    // agent (AgentRegistry).
    var plusDirs: [String?] = []
    var wtDirs: [String?] = []
    var agentDirs: [(key: String, dir: String?)] = []
    wc.sidebar.onNewTabInDir = { plusDirs.append($0) }
    wc.sidebar.onNewWorktreeInDir = { wtDirs.append($0) }
    wc.sidebar.onNewAgentSessionInDir = { agentDirs.append(($0, $1)) }
    let plusMenu = wc.sidebar.spacePlusMenu(dir: repoDir)
    let agentCount = AgentRegistry.descriptors.count
    check(plusMenu.items.count == 3 + agentCount
          && plusMenu.items[0].title == "New Terminal"
          && plusMenu.items[1].title == "New Worktree…",
          "space '+' menu: terminal + worktree + flat agent entries")
    for item in plusMenu.items where item.action != nil {
        _ = NSApp.sendAction(item.action!, to: item.target, from: item)
    }
    check(plusDirs == [repoDir] && wtDirs == [repoDir],
          "menu items route to their callbacks")
    check(agentDirs.count == agentCount
          && agentDirs.allSatisfy { $0.dir == repoDir },
          "agent entries route with the section dir")

    // RepoWatcher (FSEvents): local repos are event-driven — a file
    // change fires onRootChanged with the repo root, the stores drop
    // their TTL, the next tick refetches. Positive path only; "no
    // event without change" is a timing claim the harness cannot
    // assert cheaply.
    var watchedRoots: [String] = []
    RepoWatcher.shared.onRootChanged = { watchedRoots.append($0) }
    RepoWatcher.shared.watch(repoDir)
    runsh("cd '\(repoDir)' && echo change > touched.txt")
    settle(90)   // FSEvents latency 0.4s + delivery (heavy-load headroom)
    check(watchedRoots.contains(repoDir),
          "RepoWatcher fires for a local repo change (roots=\(watchedRoots))")
    // Closing a pane must REMOVE its view from the grid, not just
    // retire the host: a retired-but-attached view kept painting (the
    // ghost agent pane after closing its tab).
    print("— pane grid: closed pane's view leaves the hierarchy —")
    final class StubPaneHost: NSView, PaneHosting {
    func focusAsPane() {}  // stub pane — keyboard never targets it

        let hostKey: HostKey
        var retired = false
        init(_ key: HostKey) { self.hostKey = key; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }
        var windowVisible = true
        func setVisible(_ visible: Bool) { isHidden = !visible }
        func syncCoreVisibility() {}
        func createSurfaceIfNeeded() {}
        func retire() { retired = true }   // deliberately does NOT detach
    }
    do {
        let grid = PaneGridView()
        grid.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let k1 = HostKey(workspace: UUID(), pane: "p1")
        let k2 = HostKey(workspace: UUID(), pane: "p2")
        let h1 = StubPaneHost(k1)
        let h2 = StubPaneHost(k2)
        grid.setVisiblePanes([(k1, h1, NSRect(x: 0, y: 0, width: 1, height: 1))],
                             keepAlive: [])
        check(h1.superview === grid, "pane 1 attached to the grid")
        grid.setVisiblePanes([(k2, h2, NSRect(x: 0, y: 0, width: 1, height: 1))],
                             keepAlive: [])
        check(h1.retired, "closed pane's host retired")
        check(h1.superview == nil, "closed pane's view removed from the hierarchy")
    }

    RepoWatcher.shared.onRootChanged = nil


    // The sidebar's fetch carries the root beside the summary — it is
    // the watcher's key and the invalidation mapping — and the space
    // root (main worktree first in `worktree list`).
    let fetched = GitStatusStore.fetch(cwd: repoDir, host: nil)
    check(fetched?.root == repoDir && fetched?.spaceRoot == repoDir
              && fetched?.summary?.branch == "main",
          "git fetch returns root + space root + branch (root=\(fetched?.root ?? "-"))")

    // rootChanged: a RepoWatcher event refetches immediately (not at
    // tick cadence); the surface tick then reads the CACHE (TTL fresh
    // → no exec) and the new file appears on the panel.
    var repoUpdated = false
    ScmStore.shared.onRepoUpdated = { _ in repoUpdated = true }
    runsh("cd '\(repoDir)' && echo x > wt-event.txt")
    ScmStore.shared.rootChanged(root: repoDir)
    settle(90)
    check(repoUpdated, "rootChanged refetches and reports")
    panel.refresh(force: false)   // the surface tick: cache read, no exec
    settle()
    check(rowKeys(panel).contains("row:untracked:wt-event.txt"),
          "event refetch reaches the panel via the cache-read path")
    ScmStore.shared.onRepoUpdated = nil

    panel.removeFromSuperview()
    try? FileManager.default.removeItem(atPath: mdFixture)
    runsh("cd '\(repoDir)' && git worktree prune")
    try? FileManager.default.removeItem(atPath: repoDir)
    try? FileManager.default.removeItem(atPath: expectTarget)

    print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
    exit(failures == 0 ? 0 : 1)
}

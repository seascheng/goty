// goty — see CLAUDE.md for the working principles.
import GhosttyKit
import AppKit

extension AppDelegate {

    func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(title: "Goty", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(menuOpenSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let shellItem = NSMenuItem(title: "Shell", action: nil, keyEquivalent: "")
        let shellMenu = NSMenu()
        shellMenu.addItem(withTitle: "New Space", action: #selector(menuNewTab), keyEquivalent: "t")
        shellMenu.addItem(withTitle: "New Claude Code Space", action: #selector(menuNewAgentTab), keyEquivalent: "n")
        let askAI = NSMenuItem(title: "Ask AI…", action: #selector(menuAskAI), keyEquivalent: "a")
        askAI.keyEquivalentModifierMask = [.command, .shift]
        askAI.target = self
        shellMenu.addItem(askAI)
        let agentMenu = NSMenu()
        for (command, spec) in AgentCatalog.pickerOrder {
            let item = NSMenuItem(title: spec.label, action: #selector(menuNewAgentTabFrom(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = command
            // Official brand logo when the asset exists (AgentIcons.swift),
            // SF Symbol otherwise.
            item.image = AgentBrandIcons.image(for: command)
                ?? menuItemIcon(spec.icon, pointSize: 11)
            agentMenu.addItem(item)
        }
        let agentItem = NSMenuItem(title: "New Agent Space", action: nil, keyEquivalent: "")
        agentItem.submenu = agentMenu
        shellMenu.addItem(agentItem)
        shellMenu.addItem(withTitle: "Close Space", action: #selector(menuCloseTab), keyEquivalent: "w")
        shellMenu.addItem(.separator())
        shellMenu.addItem(withTitle: "Split Right", action: #selector(menuSplitRight), keyEquivalent: "d")
        let splitDown = NSMenuItem(title: "Split Down", action: #selector(menuSplitDown), keyEquivalent: "D")
        splitDown.keyEquivalentModifierMask = [.command, .shift]
        shellMenu.addItem(splitDown)
        shellItem.submenu = shellMenu
        main.addItem(shellItem)

        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        let viewMenu = NSMenu()
        viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(menuToggleSidebarRegion),
                         keyEquivalent: "b")
        viewMenu.addItem(withTitle: "Toggle Right Panel", action: #selector(menuToggleRightPanelRegion),
                         keyEquivalent: "j")
        let editorToggle = NSMenuItem(title: "Toggle Editor", action: #selector(menuToggleEditor),
                                      keyEquivalent: "E")
        editorToggle.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(editorToggle)
        viewItem.submenu = viewMenu
        main.addItem(viewItem)
        NSApp.mainMenu = main
    }
    @objc private func menuToggleSidebarRegion() { wc?.toggleSidebar() }
    @objc private func menuToggleRightPanelRegion() { wc?.toggleRightPanel() }
    @objc private func menuOpenSettings() {
        settingsWindow().show(over: window)
    }
    @objc func menuNewTab() { coordinator.newTab() }
    @objc func menuNewAgentTab() { coordinator.newAgentTab() }
    @objc private func menuNewAgentTabFrom(_ sender: NSMenuItem) {
        if let command = sender.representedObject as? String {
            coordinator.newAgentTab(command: command)
        }
    }
    @objc func menuCloseTab() { coordinator.closeTab() }
    @objc func menuSplitRight() { coordinator.splitPane(vertical: false) }
    @objc func menuSplitDown() { coordinator.splitPane(vertical: true) }

    /// ⌘⇧A: the focused pane's AI card in request-input mode. Falls back
    /// to the focused tab's active pane when the host pool holds no hit.
    @objc private func menuAskAI() {
        guard let store = coordinator.store, let ws = store.focused,
              let pane = coordinator.activePane(of: ws) else { return }
        // The ask is app-global: clear any other pane's ask card first.
        for host in hostPool.values { host.hideAITaskIfInputMode() }
        hostPool[HostKey(workspace: ws.id, pane: pane.id)]?.openAIInputMode()
    }

    /// App-level config change (Settings writes, or a reload from the
    /// config page): the resolved config is the chrome's source of
    /// truth (Chrome.swift). Window-level surfaces flip now; row-level
    /// fills painted at construction repaint when their view rebuilds
    /// (the viewDidMoveToWindow rule).
    // ponytail: partial live repaint — a retheme broadcast is the
    // upgrade path if stale rows ever read wrong.
    /// One walk covers every chrome surface in every window: views
    /// that bake colors at build time conform to ThemeRefreshable;
    /// no per-surface observers, no rebuild paths to remember.
    @objc func themeFanout() {
        for w in NSApp.windows { w.contentView?.rethemeSubtree() }
    }

    @objc func ghosttyConfigChanged(_ note: Notification) {
        guard note.object == nil,
              let cfg = note.userInfo?[Notification.Name.GhosttyConfigChangeKey]
                  as? Ghostty.Config
        else { return }
        let candidate = ChromeTheme.from(cfg)
        if ProcessInfo.processInfo.environment["GOTY_AI_DEBUG"] == "1" {
            let name = ChromeTheme.configuredThemeName(cfg) ?? "nil"
            FileHandle.standardError.write("THEME change old=\(Chrome.theme.background.usingColorSpace(.deviceRGB).map { String(format: "%.2f", $0.redComponent) } ?? "?") new=\(candidate.background.usingColorSpace(.deviceRGB).map { String(format: "%.2f", $0.redComponent) } ?? "?") theme=\(name)\n".data(using: .utf8)!)
        }
        wc?.applyChromeTheme(cfg: cfg)

        // Re-color work on a REAL change — the WHOLE theme, not just
        // the background: two themes can share a background and differ
        // in foreground/accent (the light-theme report: fg-only flips
        // were swallowed here and every baked label stayed stale).
        // Font-size-style writes change nothing and skip straight
        // through; the settings page rebuilds WITHOUT rebuilding its
        // page when IT wrote the change (the rebuild swaps the slider
        // mid-drag — the thumb-snap report).
        guard candidate != Chrome.theme else { return }
        Chrome.theme = candidate
        // OUR chrome follows the terminal theme too (the tty7 rule): the
        // render paths rebuild rows/headers with fresh colors — the
        // generation salt makes same-data renders rebuild anyway.
        wc?.sidebar.retheme()
        wc?.terminalArea.tabStrip.retheme()
        wc?.rightPanel.needsDisplay = true
        refresh()
        refreshConnectionChrome()
        settingsWindowBacking?.rethemeNow()
    }

    /// Split requested by the terminal itself (right-click menu's
    /// Split Right/Left/Down/Up, or a user Ghostty keybind): map the
    /// surface back to its pane — the clicked pane becomes the split
    /// target (the click monitor focused it on right-mouse-down).
    @objc func ghosttySplitRequested(_ note: Notification) {
        guard let view = note.object as? Ghostty.SurfaceView,
              let host = hostPool.values.first(where: { $0.surfaceView === view })
        else { return }
        coordinator.focusPane(wsId: host.hostKey.workspace, paneId: host.paneId)
        let vertical: Bool, after: Bool
        switch note.userInfo?["direction"] as? ghostty_action_split_direction_e {
        case GHOSTTY_SPLIT_DIRECTION_DOWN: (vertical, after) = (true, true)
        case GHOSTTY_SPLIT_DIRECTION_UP: (vertical, after) = (true, false)
        case GHOSTTY_SPLIT_DIRECTION_LEFT: (vertical, after) = (false, false)
        default: (vertical, after) = (false, true)   // RIGHT
        }
        coordinator.splitPane(vertical: vertical, after: after)
    }

    /// Paste protection: libghostty holds the clipboard request until
    /// the embedder answers. Ask through the standard dialog, then
    /// complete the pending request either way — a dropped request is
    /// a paste that goes nowhere.
    @objc func ghosttyConfirmClipboard(_ note: Notification) {
        guard let view = note.object as? Ghostty.SurfaceView,
              let str = note.userInfo?[Ghostty.Notification.ConfirmClipboardStrKey] as? String,
              let request = note.userInfo?[Ghostty.Notification.ConfirmClipboardRequestKey]
                  as? Ghostty.ClipboardRequest
        else { return }
        let state = note.userInfo?[Ghostty.Notification.ConfirmClipboardStateKey]
            as? UnsafeMutableRawPointer

        let title: String
        if case .paste = request {
            let lines = str.components(separatedBy: .newlines).count
            title = "Paste \(lines) lines?"
        } else {
            title = "Clipboard Access"
        }
        let preview = str.count > 160 ? String(str.prefix(160)) + "…" : str
        let ok = Dialog.confirm(title: title,
                                detail: request.text() + "\n\n" + preview,
                                action: "Confirm")

        switch request {
        case .paste, .osc_52_read:
            guard let surface = view.surface else { return }
            Ghostty.App.completeClipboardRequest(
                surface, data: str, state: state, confirmed: ok)
        case .osc_52_write(let pb):
            guard let pb, ok else { return }
            pb.clearContents()
            pb.setString(str, forType: .string)
        }
    }

    /// Focuses the sidebar row so its inline editor can begin (the row
    /// itself owns the field swap).
    func renameTabFocusField(index: Int) {
        wc.sidebar.beginRename(index: index)
    }

    /// Rename from a surface with no inline field (the collapsed-mode
    /// tab strip): the prompt carries the current title; an emptied
    /// answer CLEARS the override (the inline rule, same channel).
    func renameTabPrompt(index: Int) {
        guard let ws = coordinator.store?.focused,
              ws.tabs.indices.contains(index) else { return }
        let tab = ws.tabs[index]
        let current = tab.userTitle
            ?? coordinator.surfaceTitle(for: tab)
            ?? tab.name
        guard let name = Dialog.promptText(title: "Rename Tab",
                                           placeholder: "tab title",
                                           initial: current) else { return }
        coordinator.renameTab(index: index,
                              name: name.trimmingCharacters(in: .whitespaces))
    }
}

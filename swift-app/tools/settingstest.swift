// settingstest.swift — headless contract tests for Settings.
//
// Two surfaces: the ghostty-config document (surgical edits preserve
// hand-written files) and the settings window's apply pipeline
// (control state ← file, control act → file). The apply path must
// never touch lines it does not manage.
//
// Built and run by run-tests.sh; NOT part of the app binary.
import AppKit
@testable import goty

@main
enum SettingsTest {
    static func main() {
        var failures = 0
        func check(_ cond: Bool, _ name: String) {
            if cond { print("  ok  \(name)") } else { failures += 1; print("FAIL  \(name)") }
        }

        _ = NSApplication.shared   // AppKit machinery; we never run() it.

        print("— GhosttyConfigDocument —")
        let src = """
        # my config
        font-size = 14
        theme=Dracula

        # idle comment
        font-size = 20
        cursor-style = bar
        """
        let doc = GhosttyConfigDocument(text: src)
        check(doc.rendered == src, "unedited document round-trips byte-identical")
        check(doc.value("font-size") == "14", "first occurrence wins")
        check(doc.value("theme") == "Dracula", "key=value without spaces parses")
        check(doc.value("missing") == nil, "absent key is nil")

        var edited = doc
        edited.set("theme", "Arthur")
        let afterSet = edited.rendered
        check(edited.value("theme") == "Arthur", "set rewrites the value")
        check(afterSet.contains("# my config"), "comments preserved")
        check(afterSet.contains("# idle comment"), "mid-file comments preserved")
        check(afterSet.contains("cursor-style = bar"), "unmanaged keys untouched")
        check(!afterSet.contains("theme=Dracula"), "old value gone")
        check(afterSet.components(separatedBy: "cursor-style").count == 2,
              "no phantom lines added")

        edited.set("font-size", "16")
        check(edited.value("font-size") == "16", "set rewrites first occurrence")
        check(edited.rendered.contains("font-size = 16"), "canonical spacing on rewrite")
        check(!edited.rendered.contains("font-size = 14"), "old first value gone")
        check(!edited.rendered.contains("font-size = 20"), "duplicate collapsed")

        edited.set("window-height", "40")
        check(edited.value("window-height") == "40", "new key appends")

        edited.remove("font-size")
        check(edited.value("font-size") == nil, "remove clears the key")
        check(edited.value("theme") == "Arthur", "siblings survive remove")
        check(!edited.rendered.contains("font-size"), "no font-size line remains")

        print("— GhosttyConfigStore —")
        let tmp = NSTemporaryDirectory() + "goty-settings-\(getpid()).ghostty"
        let store = GhosttyConfigStore(url: URL(fileURLWithPath: tmp))
        var onDisk = GhosttyConfigDocument(text: "theme = Dracula\n")
        onDisk.set("font-size", "15")
        try? store.save(onDisk)
        let reloaded = store.load()
        check(reloaded.value("theme") == "Dracula", "store round-trips values")
        check(reloaded.value("font-size") == "15", "store round-trips second key")

        // Missing file → empty document (first write creates it).
        let freshPath = NSTemporaryDirectory() + "goty-settings-fresh-\(getpid()).ghostty"
        try? FileManager.default.removeItem(atPath: freshPath)
        let fresh = GhosttyConfigStore(url: URL(fileURLWithPath: freshPath))
        check(fresh.load().value("theme") == nil, "missing file loads empty")
        var freshDoc = GhosttyConfigDocument(text: "")
        freshDoc.set("theme", "Catppuccin")
        try? fresh.save(freshDoc)
        check(fresh.load().value("theme") == "Catppuccin", "save creates the file")
        try? FileManager.default.removeItem(atPath: freshPath)

        print("— Settings window —")
        // Offscreen window from birth (the layouttest rule: no test
        // surface ever reaches the user's screen).
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.setFrameOrigin(NSPoint(x: 30000, y: 30000))
        let root = SettingsRootView(store: store, app: nil)
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root
        root.layoutSubtreeIfNeeded()

        check(root.sectionRowCountForTest == 4, "four sections listed")
        let page = root.currentPageForTest
        check(page != nil, "appearance page built on launch")

        // The order-front autosize regression lock: the window must keep
        // its size and the page must fill the right pane (the tiny-window
        // report — a collapsed constraint graph shrank the window to the
        // section list plus one line of text).
        let swc = SettingsWindowController(store: store, app: nil)
        swc.window.makeKeyAndOrderFront(nil)
        swc.root.layoutSubtreeIfNeeded()
        let kf = swc.window.frame
        check(kf.width >= 759 && kf.height >= 559,
              "window keeps its size on order-front (got \(kf.size))")
        let shownPage = swc.root.currentPageForTest
        check(shownPage != nil && shownPage!.frame.width > 300,
              "page fills the right pane (got \(shownPage?.frame ?? .zero))")
        if let popup = shownPage?.controlsByKey["theme"] as? NSPopUpButton {
            check(popup.frame.width >= 179,
                  "theme popup keeps min width (got \(popup.frame.width))")
        }
        check(root.fittingSize.width > 400 && root.fittingSize.height > 300,
              "root fitting size substantial (got \(root.fittingSize))")

        // Control state reads the file (headless: no live app config).
        if let popup = page?.controlsByKey["theme"] as? ChromePopup {
            check(popup.selectedLabelForTest == "Dracula",
                  "theme popup selects the file's theme (got \(popup.selectedLabelForTest ?? "-"))")
        } else {
            check(false, "theme control is a ChromePopup")
        }
        if let slider = page?.controlsByKey["font-size"] as? NSView,
           let s = slider.subviews.first(where: { $0 is ChromeSlider }) as? ChromeSlider {
            check(abs(s.valueForTest - 15) < 0.01,
                  "font-size slider shows the file value (got \(s.valueForTest))")
        } else {
            check(false, "font-size control carries a ChromeSlider")
        }

        // Layout lock: every FORM page's rows are EXACTLY 56pt (the
        // oversized-first-row report — native intrinsic sizes must
        // never stretch a row). Config File is a document page
        // (path card + actions), not rows.
        for sec in SettingsSection.allCases where sec != .configFile {
            root.selectForTest(sec)
            root.layoutSubtreeIfNeeded()
            let heights = root.currentPageForTest?.rowHeightsForTest ?? []
            check(!heights.isEmpty && heights.allSatisfy { $0 == 56 },
                  "\(sec.title) rows uniform 56pt (got \(heights))")
        }
        root.selectForTest(.appearance)

        // Hit-test lock (the "all sliders dead" report): every control
        // must be reachable by a real click at its center, in WINDOW
        // coordinates — a zero-height ancestor makes a control draw
        // fine but swallow every click.
        for (sec, keys) in [(SettingsSection.appearance, ["theme", "font-family", "font-size",
                                                          "background-opacity", "background-blur"]),
                            (SettingsSection.terminal, ["cursor-style", "scrollback-limit",
                                                         "mouse-hide-while-typing", "confirm-close-surface",
                                                         "macos-option-as-alt"])] {
            root.selectForTest(sec)
            root.layoutSubtreeIfNeeded()
            for key in keys {
                guard let target = root.currentPageForTest?.controlsByKey[key],
                      let win = root.window else {
                    check(false, "\(key) control present for hit-test"); continue
                }
                let centerInWindow = target.convert(
                    NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
                let hit = win.contentView?.hitTest(centerInWindow)
                var chain = hit
                var found = false
                while let v = chain {
                    if v === target { found = true; break }
                    chain = v.superview
                }
                check(found, "\(key) is clickable at its center (hit \(hit.map { String(describing: type(of: $0)) } ?? "nil"))")
            }
        }
        root.selectForTest(.appearance)

        // Apply pipeline: act → file, surgical.
        root.apply("theme", "Arthur")
        let afterApply = store.load()
        check(afterApply.value("theme") == "Arthur", "apply writes the key")
        check(afterApply.value("font-size") == "15", "apply leaves siblings alone")

        root.apply("theme", nil)
        check(store.load().value("theme") == nil, "nil apply returns to default")

        // Toggles reflect the file, headless path included; the
        // CONTROL act (click) drives apply like a real user.
        root.apply("mouse-hide-while-typing", "false")
        root.selectForTest(.terminal)
        let terminalPage = root.currentPageForTest
        if let sw = terminalPage?.controlsByKey["mouse-hide-while-typing"] as? ChromeToggle {
            check(sw.isOnForTest == false, "toggle reads false from the file")
            sw.setForTest(true)
            check(store.load().value("mouse-hide-while-typing") == "true",
                  "toggle click writes the file")
        } else {
            check(false, "mouse toggle is a ChromeToggle")
        }
        if let popup = terminalPage?.controlsByKey["cursor-style"] as? ChromePopup {
            check(popup.selectedLabelForTest == "Block",
                  "cursor-style falls back to block (got \(popup.selectedLabelForTest ?? "-"))")
            popup.pickForTest("Underline")
            check(store.load().value("cursor-style") == "underline",
                  "popup pick writes the file")
        } else {
            check(false, "cursor-style control is a ChromePopup")
        }

        // Slider act: debounced trailing write (drag ticks coalesce;
        // the write lands after the runloop drains the deadline).
        if let wrap = terminalPage?.controlsByKey["scrollback-limit"] as? NSView,
           let s = wrap.subviews.first(where: { $0 is ChromeSlider }) as? ChromeSlider {
            s.setForTest(20)
            let deadline = Date().addingTimeInterval(0.5)
            while Date() < deadline,
                  store.load().value("scrollback-limit") != "20000000" {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            check(store.load().value("scrollback-limit") == "20000000",
                  "slider drag writes after the debounce")
        } else {
            check(false, "scrollback control carries a ChromeSlider")
        }

        root.selectForTest(.configFile)
        check(root.currentPageForTest !== terminalPage, "section switch swaps the page")

        // Search (tty7 Settings search): matches names and keys across
        // sections; clearing restores the section page.
        root.searchForTest("scrollback")
        let searchPage = root.currentPageForTest
        check(searchPage?.controlsByKey["scrollback-limit"] != nil,
              "search finds scrollback by name")
        check(searchPage?.controlsByKey["theme"] == nil,
              "non-matching rows stay out of results")
        root.searchForTest("mouse")
        check(root.currentPageForTest?.controlsByKey["mouse-hide-while-typing"] != nil,
              "search matches by key fragment")
        // A 1-char query matches dozens of specs — the results must
        // SCROLL inside the fixed viewport, never grow the window's
        // content (the "window became very long" report: the page WAS
        // the content size).
        root.searchForTest("s")
        root.layoutSubtreeIfNeeded()
        if let results = root.currentPageForTest {
            let viewport = root.pageHostForTest.bounds.height
            check(results.fittingSize.height > viewport
                  && root.fittingSize.height < results.fittingSize.height,
                  "broad search scrolls (page \(Int(results.fittingSize.height))pt > viewport \(Int(viewport))pt; root \(Int(root.fittingSize.height))pt stays put)")
        } else {
            check(false, "1-char search produced a results page")
        }
        root.searchForTest("")
        check(root.currentPageForTest !== searchPage,
              "cleared search restores the section page")

        // Theme swatch helpers: a known bundled theme parses to colors.
        if let (bg, fg) = SettingsRootView.themeColors("Arthur") {
            check(bg != fg, "Arthur theme colors parse and differ")
            _ = SettingsRootView.swatchImage(bg: bg, fg: fg)
        } else {
            check(true, "Arthur theme file absent here — swatch parse skipped")
        }

        print("— AI settings —")
        // Isolate every keychain touch: the settings page's live-write
        // path and the round-trip below must never touch the user's real
        // goty.ai items (ACL prompts + credential clobbering).
        Keychain.serviceOverrideForTests = "goty.ai.test"
        let aiPrefs = AppPreferences(defaults: UserDefaults(suiteName: "aitest")!)
        aiPrefs.aiBaseUrl = "https://api.example.com/v1"
        aiPrefs.aiModel = "m-1"
        check(aiPrefs.aiBaseUrl == "https://api.example.com/v1" && aiPrefs.aiModel == "m-1",
              "ai prefs round-trip")
        Keychain.setSecret(nil, for: "aitest-key")
        Keychain.setSecret("sekrit", for: "aitest-key")
        check(Keychain.secret(for: "aitest-key") == "sekrit", "keychain round-trip")
        Keychain.setSecret(nil, for: "aitest-key")
        check(Keychain.secret(for: "aitest-key") == nil, "keychain delete")

        // The AI page: three rows, live-wired to prefs + keychain.
        root.selectForTest(.ai)
        root.layoutSubtreeIfNeeded()
        let aiPage = root.currentPageForTest
        check(aiPage != nil, "ai page builds")
        check(aiPage?.controlsByKey["ai-base-url"] is ChromeInput, "base url field present")
        check(aiPage?.controlsByKey["ai-model"] is ChromeInput, "model field present")
        check(aiPage?.controlsByKey["ai-api-key"] is ChromeInput, "api key field present (themed, not native)")
        // Live write path: a user act (Return) writes the pref directly.
        if let f = aiPage?.controlsByKey["ai-model"] as? ChromeInput {
            f.stringValue = "gpt-test"
            f.onReturn?()
            check(AppPreferences.shared.aiModel == "gpt-test", "model field writes the pref live")
        } else {
            check(false, "model field writes the pref live")
        }
        // API key: Return commits to the Keychain; the field clears
        // (the secret is never echoed) and an empty commit clears it.
        if let f = aiPage?.controlsByKey["ai-api-key"] as? ChromeInput {
            f.stringValue = "k-test"
            f.onReturn?()
            check(Keychain.secret(for: "aiApiKey") == "k-test",
                  "api key field writes keychain live")
            check(f.stringValue.isEmpty, "api key field clears after commit (no secret echo)")
            f.stringValue = ""
            f.onReturn?()
            check(Keychain.secret(for: "aiApiKey") == nil,
                  "empty commit clears the keychain item")
        } else {
            check(false, "api key field writes keychain live")
        }
        AppPreferences.shared.aiModel = ""   // leave shared prefs clean

        try? FileManager.default.removeItem(atPath: tmp)
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
        exit(failures == 0 ? 0 : 1)
    }
}

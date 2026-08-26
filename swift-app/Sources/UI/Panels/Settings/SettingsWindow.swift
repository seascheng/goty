// goty — see CLAUDE.md for the working principles.
import AppKit
import GhosttyKit

// MARK: - Settings window (tty7 layout: sections left, rows right)
//
// Everything here writes goty's OWN ghostty config (GhosttyConfigStore)
// one key at a time and reloads libghostty live — hand edits, comments
// and unknown keys are never touched (GhosttyConfigDocument). Section
// list on the left follows tty7's settings shape; rows are
// label-left / control-right, and every change applies immediately
// (no dirty tracking, no Save button — the tty7 model).

enum SettingsSection: String, CaseIterable {
    case appearance, terminal, configFile, ai

    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .terminal: return "Terminal"
        case .configFile: return "Config File"
        case .ai: return "AI"
        }
    }
    var symbol: String {
        switch self {
        case .appearance: return "paintpalette"
        case .terminal: return "chevron.left.forwardslash.chevron.right"
        case .configFile: return "doc.text"
        case .ai: return "sparkles"
        }
    }
}

/// One section in the left column: icon + title, click selects, the
/// selected row keeps the persistent pill fill (SSHHostRow recipe).
final class SettingsRootView: NSView {
    override var isFlipped: Bool { true }

    let store: GhosttyConfigStore
    /// The live app; nil in headless tests (file values stand in).
    private weak var app: Ghostty.App?
    /// Window-translucency hook (blur needs the live ghostty_app_t).
    var liveAppForTranslucency: (() -> ghostty_app_t?)?
    private var section: SettingsSection = .appearance
    /// Non-empty while a search is live (tty7 Settings search: matches
    /// setting names and keywords — the page becomes the results).
    private var searchQuery = ""
    private let searchField = ChromeInput(placeholder: "Search settings", icon: "magnifyingglass")
    private var sectionRows: [SettingsSectionRow] = []
    private let pageHost = NSView()  // no scrollview: pages are fixed row lists that always fit

    init(store: GhosttyConfigStore, app: Ghostty.App?) {
        self.store = store
        self.app = app
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = chromeSurface(Chrome.theme.background).cgColor

        // Top strip (44pt): window title + config path — the traffic
        // lights' band (transparent titlebar, app chrome).
        let headerStrip = NSView()
        headerStrip.wantsLayer = true
        headerStrip.layer?.backgroundColor = chromeSurface(Chrome.theme.topBarBackground).cgColor
        headerStrip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerStrip)

        let windowTitle = NSTextField(labelWithString: "SETTINGS")
        windowTitle.attributedStringValue = NSAttributedString(
            string: "SETTINGS",
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                         .foregroundColor: Chrome.theme.foreground,
                         .kern: 0.8])
        windowTitle.translatesAutoresizingMaskIntoConstraints = false
        headerStrip.addSubview(windowTitle)

        let home = NSHomeDirectory()
        let rawPath = store.url.path
        let pathLabel = NSTextField(labelWithString: "")
        pathLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        pathLabel.textColor = Chrome.theme.secondaryText
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1
        pathLabel.cell?.wraps = false
        pathLabel.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        pathLabel.stringValue = rawPath.hasPrefix(home)
            ? "~" + rawPath.dropFirst(home.count) : rawPath
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        headerStrip.addSubview(pathLabel)

        // Left column: search box (tty7's settings search) + sections.
        let listColumn = NSView()
        listColumn.translatesAutoresizingMaskIntoConstraints = false
        listColumn.wantsLayer = true
        listColumn.layer?.backgroundColor = chromeSurface(Chrome.theme.topBarBackground).cgColor
        addSubview(listColumn)

        searchField.onDidChange = { [weak self] in
            guard let self else { return }
            self.searchQuery = self.searchField.stringValue.trimmingCharacters(in: .whitespaces)
            self.rebuildPage()
        }
        searchField.onEscape = { [weak self] in
            self?.clearSearch()
        }
        listColumn.addSubview(searchField)

        var rowTop = searchField.bottomAnchor
        for s in SettingsSection.allCases {
            let row = SettingsSectionRow(s)
            row.onClick = { [weak self] in self?.select(s) }
            row.translatesAutoresizingMaskIntoConstraints = false
            listColumn.addSubview(row)
            NSLayoutConstraint.activate([
                searchField.leadingAnchor.constraint(equalTo: listColumn.leadingAnchor, constant: 10),
                searchField.trailingAnchor.constraint(equalTo: listColumn.trailingAnchor, constant: -10),
                searchField.topAnchor.constraint(equalTo: listColumn.topAnchor, constant: 10),
                searchField.heightAnchor.constraint(equalToConstant: ControlMetrics.inputHeight),
                row.leadingAnchor.constraint(equalTo: listColumn.leadingAnchor, constant: 8),
                row.trailingAnchor.constraint(equalTo: listColumn.trailingAnchor, constant: -8),
                row.topAnchor.constraint(equalTo: rowTop, constant: 6),
                row.heightAnchor.constraint(equalToConstant: 40),
            ])
            rowTop = row.bottomAnchor
            sectionRows.append(row)
        }

        let divider = HairlineView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)

        // Right column: the page host. No scrollview — every section
        // is a fixed list of ≤6 rows (≈350pt) that fits the window;
        // scroll chrome for fitting content is noise (user report).
        pageHost.wantsLayer = true
        pageHost.layer?.backgroundColor = chromeSurface(Chrome.theme.background).cgColor
        pageHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pageHost)

        // Status bar across the bottom (tty7 26pt strip).
        let statusBar = NSView()
        statusBar.wantsLayer = true
        statusBar.layer?.backgroundColor = chromeSurface(Chrome.theme.topBarBackground).cgColor
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusBar)
        let hintLabel = NSTextField(labelWithString: "")
        hintLabel.stringValue = "Changes write the config file and apply to open terminals immediately."
        hintLabel.font = .systemFont(ofSize: 11.5)
        hintLabel.textColor = Chrome.theme.secondaryText
        hintLabel.cell?.wraps = false
        hintLabel.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(hintLabel)

        NSLayoutConstraint.activate([
            headerStrip.topAnchor.constraint(equalTo: topAnchor),
            headerStrip.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerStrip.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerStrip.heightAnchor.constraint(equalToConstant: 44),
            // 84 clears the traffic-light capsules (they own the
            // top-left ~70pt — sidebar DragStrip's rule).
            windowTitle.leadingAnchor.constraint(equalTo: headerStrip.leadingAnchor, constant: 84),
            windowTitle.centerYAnchor.constraint(equalTo: headerStrip.centerYAnchor),
            windowTitle.trailingAnchor.constraint(lessThanOrEqualTo: pathLabel.leadingAnchor, constant: -8),
            pathLabel.trailingAnchor.constraint(equalTo: headerStrip.trailingAnchor, constant: -14),
            pathLabel.centerYAnchor.constraint(equalTo: headerStrip.centerYAnchor),

            listColumn.leadingAnchor.constraint(equalTo: leadingAnchor),
            listColumn.topAnchor.constraint(equalTo: headerStrip.bottomAnchor),
            listColumn.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            listColumn.widthAnchor.constraint(equalToConstant: 260),

            divider.leadingAnchor.constraint(equalTo: listColumn.trailingAnchor),
            divider.topAnchor.constraint(equalTo: headerStrip.bottomAnchor),
            divider.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            pageHost.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            pageHost.topAnchor.constraint(equalTo: headerStrip.bottomAnchor),
            pageHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            pageHost.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 26),
            hintLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 10),
            hintLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
        ])

        refreshSelection()
        rebuildPage()

        // The window autosizes to this view's fitting size on
        // order-front (the 231×66 shrink); the constraint graph must
        // therefore promise the intended content size — the same
        // numbers as the controller's initial contentRect, one source
        // would drift.
        widthAnchor.constraint(greaterThanOrEqualToConstant: 760).isActive = true
        heightAnchor.constraint(greaterThanOrEqualToConstant: 560).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder: not implemented") }

    // MARK: Sections & pages

    private func select(_ s: SettingsSection) {
        clearSearch()
        guard s != section else { return }
        section = s
        refreshSelection()
        rebuildPage()
    }

    private func clearSearch() {
        guard !searchQuery.isEmpty || !searchField.stringValue.isEmpty else { return }
        searchQuery = ""
        searchField.stringValue = ""
        rebuildPage()
    }

    private func refreshSelection() {
        // Rows are appended in allCases order — zip is the honest link.
        for (row, s) in zip(sectionRows, SettingsSection.allCases) {
            row.setSelected(s == section)
        }
    }

    /// Fresh load: external editors are expected for this file (the
    /// Config File page invites them); rebuild the current page so
    /// controls show what the disk says.
    func reload() {
        rebuildPage()
    }

    private var currentPage: NSView?

    private func rebuildPage() {
        // Remove the outgoing page first: leaving it mounted stacked
        // two constraint graphs on the same host — the crossed anchors
        // were the "first row crowds the title" layout breakage, and
        // the dead page's rows stayed clickable underneath.
        currentPage?.removeFromSuperview()
        let page = searchQuery.isEmpty ? buildPage(section) : searchPage(searchQuery)
        page.translatesAutoresizingMaskIntoConstraints = false
        pageHost.addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: pageHost.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: pageHost.trailingAnchor),
            page.topAnchor.constraint(equalTo: pageHost.topAnchor),
            page.bottomAnchor.constraint(equalTo: pageHost.bottomAnchor),
        ])
        currentPage = page
    }

    // MARK: Apply pipeline

    /// After a write: reload the app AND push the fresh config into
    /// every live surface (`ghostty_surface_update_config` — the
    /// documented hot-reload path). App-level reload alone proved
    /// unreliable for surface-owned keys (font/cursor/mouse — the
    /// "only theme works" report; theme worked because Chrome reads
    /// the file directly, bypassing libghostty). Owned by the
    /// delegate: only it knows the host pool.
    var onCommitAll: (() -> Void)?

    private var pendingWrite: DispatchWorkItem?

    /// One managed key: patch the file, save atomically, commit.
    func apply(_ key: String, _ value: String?) {
        var doc = store.load()
        if let value {
            doc.set(key, value)
        } else {
            doc.remove(key)
        }
        do {
            try store.save(doc)
        } catch {
            Dialog.error(title: "Could not save the config file",
                         detail: error.localizedDescription)
            return
        }
        commit()
    }

    /// Slider drags fire continuously; the write follows the last
    /// tick (trailing debounce). Every explicit act (popup, toggle,
    /// Return) applies immediately via apply().
    func applyDebounced(_ key: String, _ make: @escaping () -> String?) {
        pendingWrite?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.apply(key, make()) }
        pendingWrite = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
    }

    private func commit() {
        app?.reloadConfig()
        onCommitAll?()
    }

    // MARK: Effective values

    /// Effective value from the LIVE libghostty config (file value or
    /// ghostty default); with no app up (headless tests) the raw file
    /// value stands in.
    func resolvedString(_ key: String) -> String? {
        if let cfg = app?.config.config {
            var v: UnsafePointer<Int8>?
            if ghostty_config_get(cfg, &v, key, UInt(key.utf8.count)), let v {
                return String(cString: v)
            }
            return nil
        }
        return store.load().value(key)
    }

    func resolvedDouble(_ key: String) -> Double? {
        if let cfg = app?.config.config {
            var v: Double = 0
            if ghostty_config_get(cfg, &v, key, UInt(key.utf8.count)) { return v }
            return nil
        }
        return store.load().value(key).flatMap(Double.init)
    }

    func resolvedBool(_ key: String) -> Bool? {
        if let cfg = app?.config.config {
            var v = false
            if ghostty_config_get(cfg, &v, key, UInt(key.utf8.count)) { return v }
            return nil
        }
        return store.load().value(key).flatMap {
            $0 == "true" ? true : ($0 == "false" ? false : nil)
        }
    }

    // MARK: Theme inventory

    /// Theme files where ghostty looks for them (the same candidates
    /// Chrome.themeFileColors probes), deduped, sorted.
    static var availableThemes: [String] {
        let home = NSHomeDirectory()
        let dirs = [
            ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"]
                .map { $0 + "/themes" },
            home + "/Library/Application Support/goty/ghostty/themes",
            home + "/.config/ghostty/themes",
        ].compactMap { $0 }
        var seen = Set<String>()
        var result: [String] = []
        for dir in dirs {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir)
            else { continue }
            for name in names.sorted() where !name.hasPrefix(".") && seen.insert(name).inserted {
                result.append(name)
            }
        }
        return result
    }

    /// `background`/`foreground` from a theme file (the
    /// ChromeTheme.themeFileColors grammar, keyed by name).
    static func themeColors(_ name: String) -> (NSColor, NSColor)? {
        let home = NSHomeDirectory()
        let candidates = [
            ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"]
                .map { $0 + "/themes/\(name)" },
            home + "/Library/Application Support/goty/ghostty/themes/\(name)",
            home + "/.config/ghostty/themes/\(name)",
        ].compactMap { $0 }
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let text = try? String(contentsOfFile: path, encoding: .utf8)
        else { return nil }
        var hex: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let k = parts[0].trimmingCharacters(in: .whitespaces)
            guard ["background", "foreground"].contains(k) else { continue }
            hex[k] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        func color(_ key: String) -> NSColor? {
            guard let v = UInt64(hex[key]?.hasPrefix("#") == true
                ? String(hex[key]!.dropFirst()) : hex[key] ?? "", radix: 16),
                hex[key]?.count == 7 else { return nil }
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                           green: CGFloat((v >> 8) & 0xFF) / 255,
                           blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        guard let bg = color("background"), let fg = color("foreground") else { return nil }
        return (bg, fg)
    }

    /// 2x-rendered two-tone swatch (fg band on bg) for menu items.
    static func swatchImage(bg: NSColor, fg: NSColor) -> NSImage {
        let size = NSSize(width: 22, height: 12)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 44, pixelsHigh: 24,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0) else { return NSImage(size: size) }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        bg.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        fg.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: size.width * 0.32,
                                  height: size.height)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: size)
        img.addRepresentation(rep)
        return img
    }

    // MARK: Page builders

    /// One settings row as data: pages render from specs, and the
    /// search page filters the SAME specs (tty7: search matches
    /// setting names and keywords — one source for both views).
    private struct SettingSpec {
        let label: String
        let detail: String?
        let key: String?
        let makeControl: (SettingsRootView, SettingsFormPage) -> NSView

        func matches(_ query: String) -> Bool {
            let q = query.lowercased()
            return label.lowercased().contains(q)
                || (detail?.lowercased().contains(q) ?? false)
                || (key?.lowercased().contains(q) ?? false)
        }
    }

    private func buildPage(_ s: SettingsSection) -> NSView {
        let (title, subtitle): (String, String)
        switch s {
        case .configFile:
            return ConfigFilePage(
                title: "Config File",
                subtitle: "Everything in Settings writes this file; hand edits and unknown keys are preserved.",
                path: store.url.path,
                errors: app?.config.errors ?? [],
                onOpen: { [weak self] in self?.openConfigInEditor() },
                onReload: { [weak self] in
                    self?.commit()
                    self?.reload()
                })
        case .appearance:
            (title, subtitle) = ("Appearance",
                "Terminal look — written to your Ghostty config and applied to open terminals live.")
        case .terminal:
            (title, subtitle) = ("Terminal", "Cursor, scrollback, and close behavior.")
        case .ai:
            (title, subtitle) = ("AI",
                "OpenAI-compatible provider for @ai tasks. Empty Base URL or Model disables the feature.")
        }

        let page = SettingsFormPage(title: title, subtitle: subtitle)
        for spec in specs(s) {
            page.addRow(label: spec.label, detail: spec.detail, key: spec.key,
                        control: spec.makeControl(self, page))
        }
        return page
    }

    /// The vendored Ghostty.App.openURL recipe: the default app for
    /// .ghostty, else the system text editor, else the URL itself.
    /// Shared by the Config File document page and its search rows.
    func openConfigInEditor() {
        let editor = NSWorkspace.shared
            .defaultApplicationURL(forExtension: "ghostty")
            ?? NSWorkspace.shared.defaultTextEditor
        if let editor {
            NSWorkspace.shared.open([store.url],
                                    withApplicationAt: editor,
                                    configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(store.url)
        }
    }

    /// The search results page: matching specs from every section,
    /// each tagged with its section name.
    private func searchPage(_ query: String) -> SettingsFormPage {
        let page = SettingsFormPage(
            title: "\u{201C}\(query)\u{201D}",
            subtitle: "Settings matching the search.")
        for s in SettingsSection.allCases {
            for spec in specs(s) where spec.matches(query) {
                page.addRow(label: spec.label,
                            detail: "\(s.title) — \(spec.detail ?? spec.key ?? "")",
                            key: spec.key,
                            control: spec.makeControl(self, page))
            }
        }
        return page
    }

    private func specs(_ s: SettingsSection) -> [SettingSpec] {
        switch s {
        case .appearance: return appearanceSpecs()
        case .terminal: return terminalSpecs()
        case .configFile: return configFileSpecs()
        case .ai: return aiSpecs()
        }
    }

    /// The AI page writes AppPreferences + the Keychain directly (never
    /// the ghostty config); every act applies immediately — the same
    /// live model as the rest of Settings (no Save button).
    private func aiSpecs() -> [SettingSpec] {
        let prefs = AppPreferences.shared
        func input(placeholder: String, current: String,
                   write: @escaping (String) -> Void) -> ChromeInput {
            let f = ChromeInput(placeholder: placeholder)
            f.stringValue = current
            let commit = { [weak f] in
                guard let f else { return }
                write(f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            f.onReturn = commit
            f.onDidChange = commit
            f.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
            f.heightAnchor.constraint(equalToConstant: ControlMetrics.inputHeight).isActive = true
            return f
        }
        return [
            SettingSpec(label: "API Type", detail: "Wire protocol of the endpoint.",
                        key: "ai-api-type") { _, _ in
                let p = ChromePopup.make()
                p.load(options: [("OpenAI (chat/completions)", "openai"),
                                 ("Anthropic (messages)", "anthropic")],
                       current: prefs.aiApiType.isEmpty ? "openai" : prefs.aiApiType)
                p.onChange = { value in prefs.aiApiType = value ?? "openai" }
                return p
            },
            SettingSpec(label: "Base URL", detail: "Endpoint serving /chat/completions.",
                        key: "ai-base-url") { _, _ in
                input(placeholder: "https://api.openai.com/v1", current: prefs.aiBaseUrl) {
                    prefs.aiBaseUrl = $0
                }
            },
            SettingSpec(label: "Model", detail: "Model name sent with every request.",
                        key: "ai-model") { _, _ in
                input(placeholder: "gpt-5.2", current: prefs.aiModel) {
                    prefs.aiModel = $0
                }
            },
            SettingSpec(label: "API Key", detail: "Stored in the Keychain, not the config file.",
                        key: "ai-api-key") { _, _ in
                let s = NSSecureTextField()
                s.placeholderString = "sk-…"
                s.font = .systemFont(ofSize: 12.5, weight: .regular)
                s.focusRingType = .none
                s.bezelStyle = .roundedBezel
                s.usesSingleLineMode = true
                s.target = Self.self
                s.action = #selector(Self.commitAPIKey(_:))
                s.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
                s.heightAnchor.constraint(equalToConstant: ControlMetrics.inputHeight).isActive = true
                return s
            },
        ]
    }

    /// NSSecureTextField commits on Return (target/action): write the
    /// Keychain item. Lives on the root so the field's target stays
    /// alive for the window's lifetime.
    @objc fileprivate static func commitAPIKey(_ field: NSSecureTextField) {
        Keychain.setSecret(field.stringValue.isEmpty ? nil : field.stringValue,
                           for: "aiApiKey")
    }

    private func appearanceSpecs() -> [SettingSpec] {
        let doc = store.load()
        return [
            SettingSpec(label: "Theme", detail: "Color scheme for every terminal.",
                        key: "theme") { root, page in
                // A list key; the FILE is the source of truth (Chrome
                // reads it from there too), so no resolved fallback.
                var options: [(label: String, value: String?)] = [("Ghostty Default", nil)]
                for theme in Self.availableThemes { options.append((theme, theme)) }
                var swatches: [String: NSImage] = [:]
                for (label, value) in options {
                    if let name = value, let (bg, fg) = Self.themeColors(name) {
                        swatches[label] = Self.swatchImage(bg: bg, fg: fg)
                    }
                }
                return root.popup("theme", options: options,
                                  current: doc.value("theme"), page: page,
                                  swatches: swatches)
            },
            SettingSpec(label: "Font", detail: "Family name as Ghostty resolves it.",
                        key: "font-family") { root, page in
                root.textField("font-family", placeholder: "default",
                               current: doc.value("font-family"), page: page)
            },
            SettingSpec(label: "Font Size", detail: nil, key: "font-size") { root, page in
                root.slider("font-size", min: 8, max: 28, step: 0.5,
                            current: root.resolvedDouble("font-size") ?? 13,
                            format: { String(format: "%.1f pt", $0) },
                            write: { String(format: "%.1f", $0) }, page: page)
            },
            SettingSpec(label: "Background Opacity", detail: nil,
                        key: "background-opacity") { root, page in
                root.slider("background-opacity", min: 0.15, max: 1, step: 0.05,
                            current: root.resolvedDouble("background-opacity") ?? 1,
                            format: { String(format: "%.2f", $0) },
                            write: { $0 > 0.995 ? nil : String(format: "%.2f", $0) },
                            page: page)
            },
            SettingSpec(label: "Background Blur", detail: nil,
                        key: "background-blur") { root, page in
                root.slider("background-blur", min: 0, max: 40, step: 1,
                            current: root.resolvedDouble("background-blur") ?? 0,
                            format: { $0 < 0.5 ? "Off" : String(Int($0)) },
                            write: { $0 < 0.5 ? nil : String(Int($0)) }, page: page)
            },
        ]
    }

    private func terminalSpecs() -> [SettingSpec] {
        let doc = store.load()
        let cursors: [(label: String, value: String?)] = [
            ("Block", "block"), ("Bar", "bar"),
            ("Underline", "underline"), ("Hollow Block", "block_hollow"),
        ]
        let alt: [(label: String, value: String?)] = [
            ("Default", nil), ("Off", "false"), ("On", "true"),
            ("Left \u{2325}", "left"), ("Right \u{2325}", "right"),
        ]
        return [
            SettingSpec(label: "Cursor Style", detail: nil, key: "cursor-style") { root, page in
                root.popup("cursor-style", options: cursors,
                           current: root.resolvedString("cursor-style") ?? "block", page: page)
            },
            SettingSpec(label: "Scrollback", detail: "Memory per terminal, in MB.",
                        key: "scrollback-limit") { root, page in
                root.slider("scrollback-limit", min: 1, max: 100, step: 1,
                            current: (root.resolvedDouble("scrollback-limit") ?? 10_000_000) / 1_000_000,
                            format: { String(Int($0)) + " MB" },
                            write: { String(Int($0) * 1_000_000) }, page: page)
            },
            SettingSpec(label: "Hide Mouse While Typing", detail: nil,
                        key: "mouse-hide-while-typing") { root, page in
                root.toggle("mouse-hide-while-typing",
                            current: root.resolvedBool("mouse-hide-while-typing") ?? true,
                            page: page)
            },
            SettingSpec(label: "Confirm Before Closing",
                        detail: "Ask when a process is still running.",
                        key: "confirm-close-surface") { root, page in
                root.toggle("confirm-close-surface",
                            current: root.resolvedBool("confirm-close-surface") ?? true,
                            page: page)
            },
            SettingSpec(label: "Option Key Acts As Alt", detail: nil,
                        key: "macos-option-as-alt") { root, page in
                root.popup("macos-option-as-alt", options: alt,
                           current: doc.value("macos-option-as-alt"), page: page)
            },
        ]
    }

    private func configFileSpecs() -> [SettingSpec] {
        let home = NSHomeDirectory()
        let raw = store.url.path
        let shown = raw.hasPrefix(home) ? "~" + raw.dropFirst(home.count) : raw
        return [
            SettingSpec(label: "Open in Editor", detail: shown, key: nil) { root, page in
                ChromeButton.make("Open", style: .ghost) { [weak root] in
                    root?.openConfigInEditor()
                }
            },
            SettingSpec(label: "Reload", detail: "Apply external edits to every open terminal.",
                        key: nil) { root, page in
                ChromeButton.make("Reload Now", style: .primary) { [weak root] in
                    root?.commit()
                    root?.reload()
                }
            },
            SettingSpec(label: "Diagnostics",
                        detail: "Configuration errors from the last load.",
                        key: nil) { root, page in
                let errors = root.app?.config.errors ?? []
                let text = errors.isEmpty
                    ? "No errors — last load was clean."
                    : "\(errors.count) error(s) — see Console.app (goty prefix)."
                let label = NSTextField(labelWithString: text)
                label.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
                label.textColor = errors.isEmpty
                    ? Chrome.theme.secondaryText : Chrome.theme.wsDisconnected
                label.lineBreakMode = .byTruncatingMiddle
                label.maximumNumberOfLines = 1
                label.cell?.wraps = false
                return label
            },
        ]
    }

    // MARK: Control builders (the themed control layer — never native)

    private func popup(_ key: String, options: [(label: String, value: String?)],
                       current: String?, page: SettingsFormPage,
                       swatches: [String: NSImage]? = nil) -> ChromePopup {
        let p = ChromePopup.make()
        p.load(options: options, current: current)
        p.swatches = swatches
        p.onChange = { [weak self] value in self?.apply(key, value) }
        return p
    }

    private func toggle(_ key: String, current: Bool, page: SettingsFormPage) -> ChromeToggle {
        let t = ChromeToggle(on: current)
        t.onChange = { [weak self] on in self?.apply(key, on ? "true" : "false") }
        return t
    }

    /// Slider + live mono value label. Every drag tick updates the
    /// label and schedules a TRAILING debounced write (0.12s after the
    /// last tick) — the write never depends on an event phase, the
    /// old mouseUp check could miss and leave the drag unwritten.
    /// `write` returning nil returns the key to the ghostty default.
    private func slider(_ key: String, min: Double, max: Double, step: Double,
                        current: Double, format: @escaping (Double) -> String,
                        write: @escaping (Double) -> String?,
                        page: SettingsFormPage) -> NSView {
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false

        let s = ChromeSlider(value: current, min: min, max: max, step: step)
        wrap.addSubview(s)

        let valueLabel = NSTextField(labelWithString: format(current))
        valueLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        valueLabel.textColor = Chrome.theme.secondaryText
        valueLabel.alignment = .right
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(valueLabel)

        s.onChange = { [weak self] v in
            valueLabel.stringValue = format(v)
            self?.applyDebounced(key) { write(v) }
        }

        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            s.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
            valueLabel.leadingAnchor.constraint(equalTo: s.trailingAnchor, constant: 8),
            valueLabel.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
            valueLabel.widthAnchor.constraint(equalToConstant: 56),
        ])
        // The wrap OWNS a height: without it the chain only closes the
        // width, the wrap collapses to 0 tall, the slider draws outside
        // its bounds — VISIBLE but unclickable, because hitTest refuses
        // points outside a view's bounds even when children extend
        // there (the "all sliders dead" report).
        wrap.heightAnchor.constraint(
            equalToConstant: ControlMetrics.inputHeight).isActive = true
        return wrap
    }

    private func textField(_ key: String, placeholder: String, current: String?,
                           page: SettingsFormPage) -> ChromeInput {
        let f = ChromeInput(placeholder: placeholder)
        if let current { f.stringValue = current }
        f.onReturn = { [weak self, weak f] in
            guard let self, let f else { return }
            let v = f.stringValue.trimmingCharacters(in: .whitespaces)
            self.apply(key, v.isEmpty ? nil : v)
        }
        f.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        f.heightAnchor.constraint(equalToConstant: ControlMetrics.inputHeight).isActive = true
        return f
    }

    /// Esc: close the window (nothing here is a draft — every change
    /// already applied).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            window?.performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // Test surface (headless harness).
    var sectionRowCountForTest: Int { sectionRows.count }
    var currentPageForTest: SettingsFormPage? {
        pageHost.subviews.compactMap { $0 as? SettingsFormPage }.last
    }
    var pageHostForTest: NSView { pageHost }
    func selectForTest(_ s: SettingsSection) { select(s) }
    /// Types a query exactly as the field would (didChange → rebuild).
    func searchForTest(_ q: String) {
        searchField.stringValue = q
        searchQuery = q.trimmingCharacters(in: .whitespaces)
        rebuildPage()
    }
}

/// Owns the settings window. Non-modal standalone window with the
/// app's unified chrome — the SSHConfigWindowController pattern
/// (persistent controller, close does not release).
final class SettingsWindowController: NSObject {
    let window: NSWindow
    let root: SettingsRootView

    init(store: GhosttyConfigStore = GhosttyConfigStore(),
         app: Ghostty.App? = nil) {
        let root = SettingsRootView(store: store, app: app)
        self.root = root
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable,
                        .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Settings"
        window.contentView = root
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // The system appearance follows the ghostty theme (the
        // AppWindowController rule) — native text behavior renders
        // from the EFFECTIVE appearance.
        window.appearance = NSAppearance(
            named: Chrome.theme.isDark ? .darkAqua : .aqua)
        window.contentMinSize = NSSize(width: 760, height: 500)
        window.isReleasedWhenClosed = false
        self.window = window
        super.init()
    }

    /// The window follows the config's translucency: clear + blur when
    /// background-opacity < 1 (same treatment the main window gets).
    private func applyWindowTranslucency() {
        // The settings root exposes resolved values; translucency rides
        // the file/live config path it already owns.
        let translucent = (root.resolvedDouble("background-opacity") ?? 1) < 0.999
        window.isOpaque = !translucent
        window.backgroundColor = translucent ? .clear : nil
        if translucent, let gapp = root.liveAppForTranslucency?() {
            ghostty_set_window_background_blur(
                gapp, Unmanaged.passUnretained(window).toOpaque())
        }
    }

    /// Theme switched under an open settings window: rebuild the page
    /// (controls re-paint from Chrome.theme on rebuild) + system
    /// appearance + self-drawn fills.
    func rethemeNow() {
        window.appearance = NSAppearance(
            named: Chrome.theme.isDark ? .darkAqua : .aqua)
        applyWindowTranslucency()
        root.layer?.backgroundColor = chromeSurface(Chrome.theme.background).cgColor
        root.reload()
        root.needsDisplay = true
    }

    /// Re-reads the file (see reload()) and brings the window front,
    /// centered over the app's main window when one is given.
    func show(over parent: NSWindow?) {
        root.reload()
        applyWindowTranslucency()
        window.appearance = NSAppearance(
            named: Chrome.theme.isDark ? .darkAqua : .aqua)
        if let parent, parent.frame.width > 0 {
            let f = parent.frame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: f.midX - size.width / 2,
                                          y: f.midY - size.height / 2))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }
}

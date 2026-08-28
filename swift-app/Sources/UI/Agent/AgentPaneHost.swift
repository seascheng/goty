// goty — see CLAUDE.md for the working principles.
import AppKit
import WebKit

/// One GUI agent session pane: WKWebView transcript + native composer.
/// The webview is a disposable view of AgentSession state — the process
/// and its transcript live in sessiond (ring) / the agent (session file).
final class AgentPaneHost: NSView, PaneHosting, AgentSessionDelegate {
    let hostKey: HostKey

    /// Sidebar 状态接线（由 AppDelegate 桥到 coordinator）
    var onWorkingChange: ((Bool) -> Void)?
    var onPermissionPending: ((Bool) -> Void)?

    private let session: AgentSession
    private let webView: WKWebView
    private let bridge: AgentWebBridge
    private let composer = ComposerView()
    private let statusLabel = NSTextField(labelWithString: "连接中…")
    private var pendingPrompt: ACPPermissionPrompt?

    init(key: HostKey, session: AgentSession) {
        self.hostKey = key
        self.session = session

        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        // The page paints its own themed background (styles.css); without
        // this the pane flashes white until first paint.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        bridge = AgentWebBridge(webView: webView)

        super.init(frame: .zero)
        wantsLayer = true

        webView.translatesAutoresizingMaskIntoConstraints = false
        composer.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        addSubview(webView)
        addSubview(statusLabel)
        addSubview(composer)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: webView.bottomAnchor, constant: 3),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            composer.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 3),
            composer.leadingAnchor.constraint(equalTo: leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: bottomAnchor),
            composer.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            composer.heightAnchor.constraint(lessThanOrEqualToConstant: 150),
        ])

        session.delegate = self
        bridge.onPermissionOption = { [weak self] optionId in
            guard let self, let prompt = self.pendingPrompt else { return }
            self.session.respondPermission(requestID: prompt.requestID, optionId: optionId)
            self.pendingPrompt = nil
            self.onPermissionPending?(false)
        }
        composer.onSend = { [weak self] text in
            guard let self else { return }
            self.bridge.push(["type": "userMessage", "text": text])
            self.session.send(text)
        }
        composer.onStop = { [weak self] in self?.session.cancel() }

        loadWebApp()
        session.connect { [weak self] ok in
            DispatchQueue.main.async {
                self?.statusLabel.stringValue = ok ? "就绪" : "连接失败"
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    private func loadWebApp() {
        let dir = Self.webAppDirectory()
        webView.loadFileURL(dir.appendingPathComponent("index.html"),
                            allowingReadAccessTo: dir)
    }

    /// Packaged bundle first; repo fallback for run-tests/dev tools.
    static func webAppDirectory() -> URL {
        if let bundled = Bundle.main.url(forResource: "index", withExtension: "html",
                                         subdirectory: "agent-web") {
            return bundled.deletingLastPathComponent()
        }
        let repo = URL(fileURLWithPath: #filePath) // Sources/UI/Agent/AgentPaneHost.swift
            .deletingLastPathComponent().deletingLastPathComponent() // UI
            .deletingLastPathComponent().deletingLastPathComponent() // Sources
            .deletingLastPathComponent().deletingLastPathComponent() // swift-app
        return repo.appendingPathComponent("agent-web/dist")
    }

    // MARK: PaneHosting

    func setVisible(_ visible: Bool) { isHidden = !visible }
    func syncCoreVisibility() {} // webview 自管生命周期，无需 occlusion 联动
    func createSurfaceIfNeeded() {}
    var windowVisible = true
    func retire() {
        session.shutdown()
        webView.stopLoading()
    }

    // MARK: AgentSessionDelegate（Core 回调，切主线程再碰 UI）

    func session(_ session: AgentSession, didEmit events: [AgentSessionEvent]) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for event in events {
                if case .ready = event {
                    self.statusLabel.stringValue = "就绪"
                    continue
                }
                self.bridge.push(self.jsEvent(event))
            }
        }
    }

    /// One decoded ACP event → one JS event. `.ready` is UI-only and
    /// handled above; everything else crosses the bridge.
    private func jsEvent(_ event: AgentSessionEvent) -> [String: Any] {
        switch event {
        case .ready:
            return [:]
        case .messageChunk(let text):
            return ["type": "agentChunk", "text": text]
        case .thoughtChunk(let text):
            return ["type": "thoughtChunk", "text": text]
        case .toolCallUpdate(let id, let title, let kind, let status, let content):
            let contentList: [[String: Any]] = content.map { item in
                ["type": item.type, "text": item.text ?? NSNull(), "path": item.path ?? NSNull()]
            }
            return ["type": "toolCall",
                    "id": id,
                    "title": title ?? NSNull(),
                    "kind": kind ?? NSNull(),
                    "status": status ?? NSNull(),
                    "content": contentList]
        case .plan(let entries):
            let entryList: [[String: Any]] = entries.map { entry in
                ["content": entry.content,
                 "priority": entry.priority ?? NSNull(),
                 "status": entry.status ?? NSNull()]
            }
            return ["type": "plan", "entries": entryList]
        case .permissionRequested(let prompt):
            let optionList: [[String: Any]] = prompt.options.map { option in
                ["optionId": option.optionId,
                 "name": option.name,
                 "kind": option.kind ?? NSNull()]
            }
            return ["type": "permission",
                    "requestID": prompt.requestID,
                    "toolCallTitle": prompt.toolCallTitle ?? NSNull(),
                    "options": optionList]
        case .turnEnded:
            return ["type": "turnEnded"]
        }
    }

    func sessionDidFail(_ session: AgentSession, reason: String) {
        DispatchQueue.main.async { [weak self] in
            self?.statusLabel.stringValue = reason
        }
    }
}

/// Native composer bar: bordered input box + 发送/停止. NSTextView keeps
/// Chinese IME composition exactly like the rest of the app (webview
/// textarea IME is the failure mode we avoid). The box grows with up to
/// ~5 lines, then scrolls internally.
final class ComposerView: NSView, NSTextViewDelegate {
    var onSend: ((String) -> Void)?
    var onStop: (() -> Void)?

    private let inputBox = NSView()
    private let textView = NSTextView()
    private let placeholder = NSTextField(labelWithString: "输入消息…")
    private let scrollView = NSScrollView()
    private let sendButton = NSButton(title: "发送", target: nil, action: nil)
    private let stopButton = NSButton(title: "停止", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        inputBox.wantsLayer = true
        inputBox.layer?.borderColor = NSColor.separatorColor.cgColor
        inputBox.layer?.borderWidth = 1
        inputBox.layer?.cornerRadius = 8
        inputBox.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        inputBox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(inputBox)

        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 2, height: 8)
        textView.backgroundColor = .clear
        textView.delegate = self
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        inputBox.addSubview(scrollView)

        placeholder.font = .systemFont(ofSize: 13)
        placeholder.textColor = .placeholderTextColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.isEditable = false
        placeholder.isSelectable = false
        inputBox.addSubview(placeholder)

        for button in [sendButton, stopButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
        }
        sendButton.hasDestructiveAction = false
        sendButton.keyEquivalent = "\r"
        sendButton.keyEquivalentModifierMask = [.command]
        sendButton.target = self; sendButton.action = #selector(didSend)
        stopButton.target = self; stopButton.action = #selector(didStop)

        NSLayoutConstraint.activate([
            inputBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            inputBox.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            inputBox.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            inputBox.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -8),
            scrollView.leadingAnchor.constraint(equalTo: inputBox.leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: inputBox.trailingAnchor, constant: -6),
            scrollView.topAnchor.constraint(equalTo: inputBox.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: inputBox.bottomAnchor),
            placeholder.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 6),
            placeholder.topAnchor.constraint(equalTo: inputBox.topAnchor, constant: 9),
            stopButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stopButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            sendButton.trailingAnchor.constraint(equalTo: stopButton.leadingAnchor, constant: -6),
            sendButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        window?.makeFirstResponder(textView)
        updatePlaceholder()
        return ok
    }

    func textDidChange(_ notification: Notification) { updatePlaceholder() }

    private func updatePlaceholder() {
        placeholder.isHidden = !textView.string.isEmpty
    }

    @objc private func didSend() {
        // IME composition in flight: the marked string is not what the
        // user means to send yet.
        guard !textView.hasMarkedText() else { return }
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        textView.string = ""
        updatePlaceholder()
        onSend?(text)
    }

    @objc private func didStop() { onStop?() }
}

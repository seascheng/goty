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

        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        bridge = AgentWebBridge(webView: webView)

        super.init(frame: .zero)
        wantsLayer = true

        webView.translatesAutoresizingMaskIntoConstraints = false
        composer.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        addSubview(statusLabel)
        addSubview(composer)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: webView.bottomAnchor, constant: 4),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            composer.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            composer.leadingAnchor.constraint(equalTo: leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: bottomAnchor),
            composer.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
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

/// One-line native composer: Enter 发送留给 M2（需要子类化 NSTextView 拦截
/// insertNewline:）；M1 用「发送 / 停止」按钮。NSTextView keeps Chinese
/// IME composition exactly like the rest of the app (webview textarea
/// IME is the failure mode we avoid).
final class ComposerView: NSView {
    var onSend: ((String) -> Void)?
    var onStop: (() -> Void)?

    private let textView = NSTextView()
    private let sendButton = NSButton(title: "发送", target: nil, action: nil)
    private let stopButton = NSButton(title: "停止", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for button in [sendButton, stopButton] {
            button.bezelStyle = .rounded
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
        }
        sendButton.target = self; sendButton.action = #selector(didSend)
        stopButton.target = self; stopButton.action = #selector(didStop)

        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        textView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            textView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            textView.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            textView.trailingAnchor.constraint(equalTo: stopButton.leadingAnchor, constant: -8),
            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            sendButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            stopButton.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -6),
            stopButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        window?.makeFirstResponder(textView)
        return ok
    }

    @objc private func didSend() {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        textView.string = ""
        onSend?(text)
    }

    @objc private func didStop() { onStop?() }
}

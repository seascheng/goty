// goty — see CLAUDE.md for the working principles.
import AppKit
import WebKit

/// One GUI agent session pane — the Tauri model. The WKWebView is the
/// pane's entire UI (transcript, cards, composer), served from the
/// bundled assets under `goty://`; Swift is the backend: AgentSession
/// drives the ACP agent, the bridge shuttles commands and events.
final class AgentPaneHost: NSView, PaneHosting, AgentSessionDelegate {
    let hostKey: HostKey

    /// Sidebar 状态接线（由 AppDelegate 桥到 coordinator）
    var onWorkingChange: ((Bool) -> Void)?
    var onPermissionPending: ((Bool) -> Void)?

    private let session: AgentSession
    private let webView: WKWebView
    private let bridge: AgentWebBridge
    private var pendingPrompt: ACPPermissionPrompt?

    init(key: HostKey, session: AgentSession) {
        self.hostKey = key
        self.session = session

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(
            AgentSchemeHandler(root: Self.webAppDirectory()),
            forURLScheme: "goty")
        // Ephemeral store: asset caches must never outlive a build.
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
        // The page paints its own themed background; without this the
        // pane flashes white until first paint.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        bridge = AgentWebBridge(webView: webView)

        super.init(frame: .zero)
        wantsLayer = true

        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        session.delegate = self
        bridge.onSend = { [weak self] text in
            guard let self else { return }
            self.bridge.push(["type": "working", "value": true])
            self.session.send(text)
        }
        bridge.onStop = { [weak self] in self?.session.cancel() }
        bridge.onSetConfig = { [weak self] configId, value in
            self?.session.setConfigOption(id: configId, value: value)
        }
        bridge.onListSessions = { [weak self] in
            guard let self else { return }
            self.session.listSessions { summaries in
                DispatchQueue.main.async {
                    self.bridge.push(["type": "sessions", "sessions": summaries.map { summary in
                        ["sessionId": summary.sessionId,
                         "cwd": summary.cwd ?? NSNull(),
                         "title": summary.title ?? NSNull(),
                         "updatedAt": summary.updatedAt ?? NSNull(),
                         "messageCount": summary.messageCount ?? NSNull()] as [String: Any]
                    }])
                }
            }
        }
        bridge.onLoadSession = { [weak self] sessionId in
            self?.session.load(sessionId: sessionId) { _ in }
        }
        bridge.onListFiles = { [weak self] reply in
            guard let self, let cwd = self.session.cwd else { return reply([]) }
            DispatchQueue.global(qos: .userInitiated).async {
                let files = AgentFileIndex.list(root: cwd)
                DispatchQueue.main.async { reply(files) }
            }
        }
        bridge.onPermissionOption = { [weak self] optionId in
            guard let self, let prompt = self.pendingPrompt else { return }
            self.session.respondPermission(requestID: prompt.requestID, optionId: optionId)
            self.pendingPrompt = nil
            self.onPermissionPending?(false)
        }

        webView.load(URLRequest(url: URL(string: "goty://app/index.html")!))
        session.connect { [weak self] ok in
            DispatchQueue.main.async {
                self?.bridge.push(["type": "status", "text": ok ? "就绪" : "连接失败"])
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

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
                    self.bridge.push(["type": "status", "text": "就绪"])
                    continue
                }
                if case .permissionRequested(let prompt) = event {
                    self.pendingPrompt = prompt
                    self.onPermissionPending?(true)
                }
                self.bridge.push(self.jsEvent(event))
            }
        }
    }

    /// One decoded ACP event → one JS event. `.ready` is handled above.
    private func jsEvent(_ event: AgentSessionEvent) -> [String: Any] {
        switch event {
        case .ready:
            return [:]
        case .messageChunk(let text):
            return ["type": "agentChunk", "text": text]
        case .thoughtChunk(let text):
            return ["type": "thoughtChunk", "text": text]
        case .toolCallUpdate(let id, let title, let kind, let status, let content, let rawInput, let oldText):
            let contentList: [[String: Any]] = content.map { item in
                ["type": item.type, "text": item.text ?? NSNull(), "path": item.path ?? NSNull()]
            }
            return ["type": "toolCall",
                    "id": id,
                    "title": title ?? NSNull(),
                    "kind": kind ?? NSNull(),
                    "status": status ?? NSNull(),
                    "content": contentList,
                    "rawInput": rawInput ?? NSNull(),
                    "oldText": oldText ?? NSNull()]
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
        case .configChanged(let options):
            let optionList: [[String: Any]] = options.map { option in
                let choices: [[String: Any]] = option.options.map { choice in
                    ["value": choice.value, "name": choice.name,
                     "description": choice.description ?? NSNull()]
                }
                return ["id": option.id, "name": option.name,
                        "category": option.category ?? NSNull(),
                        "currentValue": option.currentValue ?? NSNull(),
                        "options": choices]
            }
            return ["type": "configOptions", "options": optionList]
        case .commandsChanged(let commands):
            let commandList: [[String: Any]] = commands.map { command in
                ["name": command.name,
                 "description": command.description ?? NSNull(),
                 "inputHint": command.inputHint ?? NSNull()]
            }
            return ["type": "commands", "commands": commandList]
        case .usageUpdate(let used, let size, let costAmount, let costCurrency):
            return ["type": "usage", "used": used ?? NSNull(), "size": size ?? NSNull(),
                    "costAmount": costAmount ?? NSNull(),
                    "costCurrency": costCurrency ?? NSNull()]
        case .turnEnded:
            return ["type": "turnEnded"]
        }
    }

    func sessionDidFail(_ session: AgentSession, reason: String) {
        DispatchQueue.main.async { [weak self] in
            self?.bridge.push(["type": "working", "value": false])
            self?.bridge.push(["type": "status", "text": reason])
        }
    }
}

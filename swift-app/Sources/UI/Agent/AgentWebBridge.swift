// goty — see CLAUDE.md for the working principles.
import AppKit
import WebKit

/// Tauri-style IPC for the agent pane's webview.
///
/// Swift → JS: `push(_:)` coalesces events per runloop turn and lands
/// them as one `window.__goty.push([...])` call (the JS side batches
/// paints through requestAnimationFrame).
/// JS → Swift: the page posts commands to the `goty` message handler —
/// `ready`, `send`, `stop`, `permission` — routed to the closures below.
final class AgentWebBridge: NSObject, WKScriptMessageHandler {
    private weak var webView: WKWebView?
    private var queue: [[String: Any]] = []
    private var flushScheduled = false
    private var jsReady = false

    var onReady: (() -> Void)?
    var onSend: ((String) -> Void)?
    var onStop: (() -> Void)?
    var onSetConfig: ((String, String) -> Void)?
    var onListSessions: (() -> Void)?
    var onLoadSession: ((String) -> Void)?
    /// `@` references: enumerate workspace files, reply via push.
    var onListFiles: ((@escaping ([String]) -> Void) -> Void)?
    var onPermissionOption: ((String) -> Void)?

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
        webView.configuration.userContentController.add(self, name: "goty")
    }

    func push(_ event: [String: Any]) {
        queue.append(event)
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            guard self.jsReady, !self.queue.isEmpty, let webView = self.webView else { return }
            let batch = self.queue
            self.queue = []
            // Structured transport: events cross as a postMessage-style
            // argument, NOT as JS source text. evaluateJavaScript with an
            // event array silently no-ops in some states (the replay-tail
            // killer: no error, no effect), while callAsyncJavaScript both
            // reports failures and has no practical size limit.
            var current: [[String: Any]] = []
            var currentBytes = 0
            func send(_ events: [[String: Any]]) {
                guard !events.isEmpty else { return }
                if #available(macOS 12.0, *) {
                    webView.callAsyncJavaScript(
                        "window.__goty.push(events);",
                        arguments: ["events": events],
                        in: nil, in: WKContentWorld.page
                    ) { result in
                        if case .failure(let error) = result {
                            print("goty: push of \(events.count) events failed:", error)
                        }
                    }
                } else if let data = try? JSONSerialization.data(withJSONObject: events),
                          let json = String(data: data, encoding: .utf8) {
                    webView.evaluateJavaScript("window.__goty.push(\(json))", completionHandler: nil)
                }
            }
            func flushSlice() {
                // A slice that fails to serialize is halved until the
                // culprit stands alone; that one is dropped with a log.
                // Never wedge the queue on one poison event.
                guard !current.isEmpty else { return }
                if JSONSerialization.isValidJSONObject(current) {
                    send(current)
                } else if current.count > 1 {
                    let half = current.count / 2
                    send(Array(current[..<half]))
                    send(Array(current[half...]))
                } else {
                    print("goty: dropped unserializable event:", current.first?["type"] ?? "?")
                }
                current = []
                currentBytes = 0
            }
            for event in batch {
                let size = (try? JSONSerialization.data(withJSONObject: [event]).count) ?? 65536
                if currentBytes + size > Self.maxSliceBytes { flushSlice() }
                current.append(event)
                currentBytes += size
            }
            flushSlice()
        }
    }

    private static let maxSliceBytes = 512 * 1024

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            jsReady = true
            onReady?()
            scheduleFlush()
        case "send":
            if let text = body["text"] as? String, !text.isEmpty { onSend?(text) }
        case "stop":
            onStop?()
        case "setConfig":
            if let configId = body["configId"] as? String,
               let value = body["value"] as? String {
                onSetConfig?(configId, value)
            }
        case "listSessions":
            onListSessions?()
        case "loadSession":
            if let sessionId = body["sessionId"] as? String {
                onLoadSession?(sessionId)
            }
        case "permission":
            if let optionId = body["optionId"] as? String {
                onPermissionOption?(optionId)
                push(["type": "permissionResolved"])
            }
        case "listFiles":
            onListFiles? { [weak self] files in
                self?.push(["type": "files", "files": files])
            }
        default:
            break
        }
    }
}

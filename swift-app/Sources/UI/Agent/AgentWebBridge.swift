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
            guard let data = try? JSONSerialization.data(withJSONObject: batch),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("window.__goty.push(\(json))", completionHandler: nil)
        }
    }

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

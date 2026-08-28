// goty — see CLAUDE.md for the working principles.
import AppKit
import WebKit

/// Tauri-style IPC for the agent pane's webview.
///
/// Swift → JS: `push(_:)` coalesces events on a short window and lands
/// them as `window.__goty.push([...])` calls through callAsyncJavaScript
/// (structured args — evaluateJavaScript with an event array silently
/// no-ops in some WebKit states, which cost us replay tails).
/// JS → Swift: the page posts commands to the `goty` message handler —
/// `ready`, `send`, `stop`, `permission` — routed to the closures below.
final class AgentWebBridge: NSObject, WKScriptMessageHandler {
    private weak var webView: WKWebView?
    private var queue: [[String: Any]] = []
    private var queuedBytes = 0
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

    /// Bulk windows: a session/load replay streams thousands of events;
    /// flushing per runloop tick serialized hundreds of main-thread page
    /// round trips (the multi-second load stall). 40ms is invisible next
    /// to a 16ms frame but collapses a whole replay into a few calls.
    private static let flushInterval: TimeInterval = 0.04
    private static let maxSliceEvents = 256

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
        webView.configuration.userContentController.add(self, name: "goty")
    }

    func push(_ event: [String: Any]) {
        queue.append(event)
        guard !flushScheduled else { return }
        flushScheduled = true
        if queue.count >= Self.maxSliceEvents {
            DispatchQueue.main.async { [weak self] in self?.drainQueue() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.flushInterval) { [weak self] in self?.drainQueue() }
        }
    }

    private func drainQueue() {
        flushScheduled = false
        queuedBytes = 0
        flush()
    }

    private func flush() {
        guard jsReady, !queue.isEmpty, let webView else { return }
        let batch = queue
        queue = []
        var current: [[String: Any]] = []
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
            // A slice that fails to serialize is halved until the culprit
            // stands alone; that one is dropped with a log. Never wedge
            // the queue on one poison event.
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
        }
        for event in batch {
            if current.count >= Self.maxSliceEvents { flushSlice() }
            current.append(event)
        }
        flushSlice()
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            jsReady = true
            onReady?()
            drainQueue()
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

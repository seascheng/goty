// goty — see CLAUDE.md for the working principles.
import AppKit
import WebKit

/// Tauri-style IPC for the agent pane's webview.
///
/// Swift → JS: `push(_:)` queues events and lands them as
/// `window.__goty.push(events)` through callAsyncJavaScript (structured
/// args — evaluateJavaScript string interpolation with event arrays
/// silently no-ops in some WebKit states, which cost us replay tails).
///
/// Delivery is strict FIFO with exactly ONE outstanding call: WebKit
/// guarantees no ordering between concurrent callAsyncJavaScript
/// completions, and a replayed transcript is order-sensitive. The next
/// slice dispatches only after the previous completion fires. A failed
/// slice retries twice, then halves; a lone event that still fails is
/// logged and dropped rather than wedging the stream — nothing else is
/// ever dropped.
///
/// JS → Swift: the page posts commands to the `goty` message handler —
/// `ready`, `send`, `stop`, `permission` — routed to the closures below.
final class AgentWebBridge: NSObject, WKScriptMessageHandler {
    private weak var webView: WKWebView?
    private var queue: [[String: Any]] = []
    private var sending = false
    private var jsReady = false

    /// Integrity accounting (replayprobe asserts these against the page).
    private(set) var pushed = 0
    private(set) var delivered = 0
    private(set) var sendFailures = 0
    private(set) var droppedPoison = 0

    var onReady: (() -> Void)?
    var onSend: ((String) -> Void)?
    var onStop: (() -> Void)?
    var onSetConfig: ((String, String) -> Void)?
    var onListSessions: (() -> Void)?
    var onLoadSession: ((String) -> Void)?
    /// `@` references: enumerate workspace files, reply via push.
    var onListFiles: ((@escaping ([String]) -> Void) -> Void)?
    var onPermissionOption: ((String) -> Void)?

    /// A replay burst is thousands of events; slices cap the per-call
    /// payload so one failure halves cheaply.
    private static let maxSliceEvents = 256

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
        webView.configuration.userContentController.add(self, name: "goty")
    }

    func push(_ event: [String: Any]) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.push(event) }
            return
        }
        queue.append(event)
        pushed += 1
        pump()
    }

    private func pump() {
        guard jsReady, !sending, webView != nil, !queue.isEmpty else { return }
        sending = true
        dispatch(limit: Self.maxSliceEvents, retries: 0)
    }

    /// Sends `queue.prefix(limit)`. Success retires it and chains the
    /// next slice; failure retries the same events, then halves — a
    /// size-related failure recovers while a poison event stands alone.
    private func dispatch(limit: Int, retries: Int) {
        guard let webView else { sending = false; return }
        let slice = Array(queue.prefix(limit))
        webView.callAsyncJavaScript(
            "window.__goty.push(events);",
            arguments: ["events": slice],
            in: nil, in: WKContentWorld.page
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.queue.removeFirst(min(slice.count, self.queue.count))
                self.delivered += slice.count
                guard !self.queue.isEmpty else {
                    self.sending = false
                    return
                }
                self.dispatch(limit: Self.maxSliceEvents, retries: 0)
            case .failure(let error):
                self.sendFailures += 1
                print("goty: push of \(slice.count) events failed:", error)
                if retries < 2 {
                    self.dispatch(limit: limit, retries: retries + 1)
                } else if limit > 1 {
                    self.dispatch(limit: limit / 2, retries: 0)
                } else {
                    self.droppedPoison += 1
                    print("goty: dropped poison event:", slice.first?["type"] ?? "?")
                    self.queue.removeFirst(min(1, self.queue.count))
                    guard !self.queue.isEmpty else {
                        self.sending = false
                        return
                    }
                    self.dispatch(limit: Self.maxSliceEvents, retries: 0)
                }
            }
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
            pump()
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

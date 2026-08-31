// goty — see CLAUDE.md for the working principles.
import AppKit
import WebKit

/// Tauri-style IPC transport shared by every goty webview (agent pane,
/// editor pane). Routing is per-app; the wire is one contract:
///
/// Swift → JS: `push(_:)` queues events and lands them as
/// `window.__goty.push(events)` through callAsyncJavaScript (structured
/// args — evaluateJavaScript string interpolation with event arrays
/// silently no-ops in some WebKit states, which cost us replay tails).
///
/// Delivery is strict FIFO with exactly ONE outstanding call: WebKit
/// guarantees no ordering between concurrent callAsyncJavaScript
/// completions, and replayed transcripts / chunked file loads are
/// order-sensitive. The next slice dispatches only after the previous
/// completion fires. A failed slice retries twice, then halves; a lone
/// event that still fails is logged and dropped rather than wedging
/// the stream — nothing else is ever dropped.
///
/// JS → Swift: the page posts commands to the `goty` message handler
/// (`ready` plus app commands); subclasses route them in `route(_:)`.
class WebBridge: NSObject, WKScriptMessageHandler {
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
                NSLog("GOTY bridge: push of %ld events failed: %@", slice.count, error.localizedDescription)
                if retries < 2 {
                    self.dispatch(limit: limit, retries: retries + 1)
                } else if limit > 1 {
                    self.dispatch(limit: limit / 2, retries: 0)
                } else {
                    self.droppedPoison += 1
                    NSLog("GOTY bridge: dropped poison event %@", slice.first?["type"] as? String ?? "?")
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
        if type == "ready" {
            jsReady = true
            onReady?()
            pump()
            return
        }
        route(body)
    }

    /// App command routing — subclass-owned.
    func route(_ message: [String: Any]) {}
}

// goty — see CLAUDE.md for the working principles.
import AppKit
import WebKit

/// Swift → JS event pump + JS → Swift message sink for one agent pane.
/// Events are coalesced per runloop turn (requestAnimationFrame on the
/// JS side batches paint; here we batch the evaluateJavaScript calls).
final class AgentWebBridge: NSObject, WKScriptMessageHandler {
    private weak var webView: WKWebView?
    private var queue: [[String: Any]] = []
    private var flushScheduled = false
    private var jsReady = false
    /// JS 审批按钮 → AgentPaneHost
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

    func pushTheme() {
        let theme = Chrome.theme
        func hex(_ color: NSColor) -> String {
            let c = color.usingColorSpace(.sRGB) ?? color
            return String(format: "#%02x%02x%02x",
                          Int(round(c.redComponent * 255)),
                          Int(round(c.greenComponent * 255)),
                          Int(round(c.blueComponent * 255)))
        }
        push(["type": "theme", "vars": [
            "--goty-bg": hex(theme.background),
            "--goty-fg": hex(theme.legibleForeground()),
            "--goty-accent": hex(theme.accent),
            "--goty-muted": hex(theme.accent),
        ]])
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
        guard let body = message.body as? [String: Any] else { return }
        switch body["type"] as? String {
        case "ready":
            jsReady = true
            pushTheme()          // ready 后先补主题，再 flush 积压事件
            scheduleFlush()
        case "permission":
            if let optionId = body["optionId"] as? String {
                onPermissionOption?(optionId)
                push(["type": "permissionResolved"])
            }
        default:
            break
        }
    }
}

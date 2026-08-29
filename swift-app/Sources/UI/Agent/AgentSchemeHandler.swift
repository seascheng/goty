// goty — see CLAUDE.md for the working principles.
import AppKit
import WebKit

/// Serves the bundled agent web app under the `goty://` scheme — the
/// Tauri model: the webview is the app surface, not a browser pointed at
/// a URL. Same-origin under goty:// means no file:// CORS restrictions
/// and no localhost port to manage.
final class AgentSchemeHandler: NSObject, WKURLSchemeHandler {
    private let root: URL

    /// `root` must be the built web app directory (bundle Resources
    /// agent-web/, repo dist fallback). Paths outside it are rejected.
    init(root: URL) {
        self.root = root.standardizedFileURL
        super.init()
    }

    private static let mimeTypes: [String: String] = [
        "html": "text/html", "js": "text/javascript", "mjs": "text/javascript",
        "css": "text/css", "json": "application/json", "svg": "image/svg+xml",
        "png": "image/png", "jpg": "image/jpeg", "gif": "image/gif",
        "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf",
        "map": "application/json", "txt": "text/plain",
    ]

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.scheme == "goty" else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        // `goty://app/index.html` — the host ("app") is a bundling
        // artifact, NOT a directory; only the path maps into the dist.
        var relative = url.path
        if relative.isEmpty || relative.hasSuffix("/") { relative += "index.html" }
        if relative.hasPrefix("/") { relative.removeFirst() }

        let file = root.appendingPathComponent(relative).standardizedFileURL
        if file.path.hasPrefix(root.path), let data = try? Data(contentsOf: file) {
            respond(task, url: url, data: data, file: file)
            return
        }
        // SPA fallback: the app is one index.html — a miss (deep link,
        // stale asset path) degrades to it instead of a blank pane.
        let index = root.appendingPathComponent("index.html")
        if let data = try? Data(contentsOf: index) {
            respond(task, url: url, data: data, file: index)
        } else {
            task.didFailWithError(URLError(.fileDoesNotExist))
        }
    }

    private func respond(_ task: WKURLSchemeTask, url: URL, data: Data, file: URL) {
        let ext = file.pathExtension.lowercased()
        let mime = Self.mimeTypes[ext] ?? "application/octet-stream"
        // no-store: the bundle changes with every app build; a cached
        // asset would pin the pane to a stale UI across relaunches.
        let response = HTTPURLResponse(url: url, statusCode: 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: [
                                        "Content-Type": mime + "; charset=utf-8",
                                        "Cache-Control": "no-store, no-cache, must-revalidate",
                                       ])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

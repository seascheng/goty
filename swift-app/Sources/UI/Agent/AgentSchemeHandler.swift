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
        var relative = url.host.map { $0 + url.path } ?? url.path
        if relative.isEmpty || relative.hasSuffix("/") { relative += "index.html" }
        if relative.hasPrefix("/") { relative.removeFirst() }

        let file = root.appendingPathComponent(relative).standardizedFileURL
        guard file.path.hasPrefix(root.path),
              let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let ext = file.pathExtension.lowercased()
        let mime = Self.mimeTypes[ext] ?? "application/octet-stream"
        let response = URLResponse(url: url, mimeType: mime,
                                   expectedContentLength: data.count,
                                   textEncodingName: "utf-8")
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

// goty — see CLAUDE.md for the working principles.
import Foundation

// MARK: - Web access tools (agent-side, pi-web-access shape)

/// fetch_content + web_search for the @ai loop. Runs on the AGENT'S Mac
/// (never the target executor — docs are fetched locally even for SSH
/// targets, the pi-web-access model). Pure helpers are test-covered;
/// the HTTP paths are plain URLSession with a browser UA.
///
/// ponytail: no SSRF/DNS preflight — the relaxed bash policy already
/// auto-runs `curl <url>` on this same machine, so URL gating here would
/// be theater. Revisit if bash tightens.
enum WebAccess {
    /// Rough body cap: big enough for real docs, small enough that one
    /// page can't eat the model's context (pi caps at 30k chars inline).
    static let maxChars = 20_000
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15"

    // MARK: fetch (readable text from any URL)

    static func fetch(url raw: String,
                      completion: @escaping (String) -> Void) {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            completion("error: not an http(s) URL: \(raw)"); return
        }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error {
                completion("error: \(error.localizedDescription)"); return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data else {
                completion("error: empty response"); return
            }
            let body = String(data: data.prefix(2_000_000), encoding: .utf8)
                ?? "<binary body, \(data.count) bytes>"
            let isHtml = (response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Type")?.contains("html") == true
                || body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<")
            let text = isHtml ? htmlToText(body) : body
            let clipped = text.count > maxChars
                ? String(text.prefix(maxChars)) + "\n…[truncated]" : text
            completion("HTTP \(status)\n\(clipped)")
        }.resume()
    }

    // MARK: search (keyless DuckDuckGo HTML, pi-web-access fallback)

    static func search(query: String,
                       completion: @escaping (String) -> Void) {
        var comp = URLComponents(string: "https://html.duckduckgo.com/html/")
        comp?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = comp?.url else {
            completion("error: bad query"); return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, error in
            if let error {
                completion("error: \(error.localizedDescription)"); return
            }
            guard let html = data.flatMap({ String(data: $0, encoding: .utf8) }) else {
                completion("error: empty response"); return
            }
            let hits = parseSearchResults(html).prefix(5)
            if hits.isEmpty {
                completion("no results (DDG may have blocked the request); "
                    + "try fetch_content on a known URL instead"); return
            }
            let lines = hits.enumerated().map { i, hit in
                "\(i + 1). \(hit.title)\n   \(hit.url)\n   \(hit.snippet)"
            }
            completion(lines.joined(separator: "\n\n")
                + "\n\nUse fetch_content on a URL above for the full page.")
        }.resume()
    }

    // MARK: pure parsers (test-covered)

    struct SearchHit {
        var title: String
        var url: String
        var snippet: String
    }

    /// DuckDuckGo HTML results: `class="result__a"` links (+ optional
    /// redirect-wrapper hrefs) and `class="result__snippet"` texts.
    static func parseSearchResults(_ html: String) -> [SearchHit] {
        var hits: [SearchHit] = []
        enumerateAnchors(html) { href, inner in
            guard href.contains("result__a"), let url = clean(href) else { return }
            hits.append(SearchHit(title: decodeEntities(stripTags(inner)), url: url, snippet: ""))
        }
        var i = 0
        enumerateAnchors(html) { href, inner in
            guard href.contains("result__snippet"), i < hits.count else { return }
            hits[i].snippet = decodeEntities(stripTags(inner))
            i += 1
        }
        return hits.filter { !$0.title.isEmpty }
    }

    /// Extract the href VALUE from an anchor's attribute blob, then
    /// unwrap `//duckduckgo.com/l/?uddg=<encoded>&…` redirects.
    private static func clean(_ attrs: String) -> String? {
        guard let r = attrs.range(of: "href=\"([^\"]*)\"", options: .regularExpression)
        else { return nil }
        let href = String(attrs[r]).dropFirst(6).dropLast()   // href="…"
        if let r2 = href.range(of: "uddg=") {
            // value runs to the next & (percent-encoded URL may itself
            // contain encoded &, never a bare one)
            var v = String(href[r2.upperBound...])
            if let amp = v.firstIndex(of: "&") { v = String(v[..<amp]) }
            return v.removingPercentEncoding ?? v
        }
        return String(href)
    }

    /// HTML → readable text: drop head/script/style, turn block ends into
    /// newlines, strip tags, decode entities, collapse whitespace.
    static func htmlToText(_ html: String) -> String {
        var s = html
        for tag in ["head", "script", "style", "nav", "footer", "svg"] {
            s = removeBlocks(named: tag, from: s)
        }
        for close in ["</p>", "</div>", "</li>", "</tr>", "</h1>", "</h2>",
                      "</h3>", "</h4>", "</pre>", "</blockquote>", "<br>"] {
            s = s.replacingOccurrences(of: close, with: "\n",
                                       options: .caseInsensitive)
        }
        s = stripTags(s)
        s = decodeEntities(s)
        // Collapse runs of blank lines the tag soup left behind.
        while s.contains("\n\n\n") { s = s.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removeBlocks(named tag: String, from s: String) -> String {
        var out = s
        let open = "<\(tag)", close = "</\(tag)>"
        while let start = out.range(of: open, options: .caseInsensitive),
              let end = out.range(of: close, options: .caseInsensitive,
                                  range: start.upperBound..<out.endIndex) {
            out.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return out
    }

    private static func stripTags(_ s: String) -> String {
        var out = ""
        var inTag = false
        for ch in s {
            if ch == "<" { inTag = true } else if ch == ">" { inTag = false }
            else if !inTag { out.append(ch) }
        }
        return out
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                               ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
                               ("&nbsp;", " ")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        // Numeric forms &#38; / &#x26;
        while let r = out.range(of: "&#x[0-9a-fA-F]+;|&#[0-9]+;",
                                options: .regularExpression) {
            let token = String(out[r]).dropFirst(2).dropLast()
            let code = token.hasPrefix("x") || token.hasPrefix("X")
                ? UInt32(token.dropFirst(), radix: 16)
                : UInt32(token)
            guard let code, let scalar = Unicode.Scalar(code) else { break }
            out.replaceSubrange(r, with: String(Character(scalar)))
        }
        return out
    }

    /// Minimal `<a …>inner</a>` scanner feeding (attribute-blob, inner).
    private static func enumerateAnchors(_ s: String, _ visit: (String, String) -> Void) {
        var search = s.startIndex
        while let open = s.range(of: "<a ", range: search..<s.endIndex) {
            guard let tagEnd = s.range(of: ">", range: open.upperBound..<s.endIndex),
                  let close = s.range(of: "</a>", range: tagEnd.upperBound..<s.endIndex)
            else { return }
            let attrs = String(s[open.upperBound..<tagEnd.lowerBound])
            let inner = String(s[tagEnd.upperBound..<close.lowerBound])
            visit(attrs, inner)
            search = close.upperBound
        }
    }
}

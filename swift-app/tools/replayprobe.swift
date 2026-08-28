// goty — see CLAUDE.md for the working principles.
// Diagnostic probe (not a test): reproduces the GUI chain end to end —
// sessiond pane + PTY + ACPClient + AgentSession (Core), then a real
// WKWebView running the real dist bundle (UI). Runs session/load on the
// newest persisted omp session, injects the mapped events, reads the
// store back. Isolates which layer loses the replay tail.
import Foundation
import AppKit
import WebKit
@testable import goty

final class ProbeSink: NSObject, WKScriptMessageHandler {
    static var ready = false
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        ProbeSink.ready = true
    }
}

final class ProbeDelegate: AgentSessionDelegate {
    let lock = NSLock()
    var eventCounts: [String: Int] = [:]
    var lastAgentText = ""
    var lastUserText = ""
    /// The exact JS event dicts AgentPaneHost would push (same mapping).
    var mapped: [[String: Any]] = []

    func session(_ session: AgentSession, didEmit events: [AgentSessionEvent]) {
        lock.lock(); defer { lock.unlock() }
        for e in events {
            switch e {
            case .ready: break
            case .userChunk(let t):
                eventCounts["userChunk", default: 0] += 1
                lastUserText += t
                mapped.append(["type": "userChunk", "text": t])
            case .messageChunk(let t):
                eventCounts["messageChunk", default: 0] += 1
                lastAgentText += t
                mapped.append(["type": "agentChunk", "text": t])
            case .thoughtChunk(let t):
                eventCounts["thoughtChunk", default: 0] += 1
                mapped.append(["type": "thoughtChunk", "text": t])
            case .toolCallUpdate(let id, let title, let kind, let status, let content, let rawInput, let oldText):
                eventCounts["toolCallUpdate", default: 0] += 1
                let contentList: [[String: Any]] = content.map { item in
                    var d: [String: Any] = ["type": item.type]
                    if let text = item.text { d["text"] = text }
                    if let path = item.path { d["path"] = path }
                    return d
                }
                var d: [String: Any] = ["type": "toolCall", "id": id, "content": contentList]
                d["title"] = title ?? NSNull()
                d["kind"] = kind ?? NSNull()
                d["status"] = status ?? NSNull()
                d["rawInput"] = rawInput ?? NSNull()
                d["oldText"] = oldText ?? NSNull()
                mapped.append(d)
            case .plan(let entries):
                eventCounts["plan", default: 0] += 1
                mapped.append(["type": "plan", "entries": entries.map { ["content": $0.content] }])
            case .permissionRequested(let prompt):
                eventCounts["permission", default: 0] += 1
                mapped.append(["type": "permission", "requestID": prompt.requestID,
                               "toolCallTitle": prompt.toolCallTitle ?? NSNull(),
                               "options": prompt.options.map { ["optionId": $0.optionId, "name": $0.name] }])
            case .turnEnded:
                eventCounts["turnEnded", default: 0] += 1
                mapped.append(["type": "turnEnded"])
            case .configChanged(let opts):
                eventCounts["config", default: 0] += 1
                mapped.append(["type": "configOptions", "options": opts.map { ["id": $0.id, "name": $0.name] }])
            case .commandsChanged(let cmds):
                eventCounts["commands", default: 0] += 1
                mapped.append(["type": "commands", "commands": cmds.map { ["name": $0.name, "description": $0.description ?? "", "input": ["hint": $0.inputHint ?? ""]] }])
            case .usageUpdate(let used, let size, let input, let output, let amount, let currency):
                eventCounts["usage", default: 0] += 1
                mapped.append(["type": "usage", "used": used ?? NSNull(), "size": size ?? NSNull(),
                               "input": input ?? NSNull(), "output": output ?? NSNull(),
                               "costAmount": amount ?? NSNull(), "costCurrency": currency ?? NSNull()])
            }
        }
    }
    func sessionDidFail(_ session: AgentSession, reason: String) {
        print("SESSION FAIL: \(reason)")
    }
}

@main
enum ReplayProbe {
    static func pump(until done: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return done()
    }

    static func main() {
        let app = NSApplication.shared

        let delegate = ProbeDelegate()
        let session = AgentSession(
            paneId: "replayprobe-\(Int(Date().timeIntervalSince1970))",
            cwd: "/Users/seascheng/Downloads/ai_project/goty-agent-gui",
            grid: SessionGrid(columns: 120, rows: 40, cellWidth: 7, cellHeight: 17),
            environment: ["TERM": "xterm-256color", "COLORTERM": "truecolor"],
            launch: AgentManifests.acpLaunch(for: "omp")!,
            daemon: .shared,
            delegate: delegate)

        var connectOk = false
        session.connect { ok in connectOk = ok }
        guard pump(until: { connectOk }, timeout: 30) else { print("FATAL: connect"); exit(1) }
        print("connect: true")

        var listed: [ACPSessionSummary]?
        session.listSessions { list in listed = list }
        guard pump(until: { listed != nil }, timeout: 30), let sid = listed?.first?.sessionId else {
            print("FATAL: no sessions"); exit(1)
        }
        print("loading:", sid)

        var loadOk = false
        session.load(sessionId: sid) { ok in loadOk = ok }
        _ = pump(until: { loadOk }, timeout: 60)
        print("load ok:", loadOk)
        pump(until: { false }, timeout: 3)

        delegate.lock.lock()
        print("EVENTS:", delegate.eventCounts.sorted { $0.key < $1.key })
        print("mapped events:", delegate.mapped.count)
        print("AGENT TAIL:", delegate.lastAgentText.suffix(150))
        let payload = delegate.mapped
        delegate.lock.unlock()

        // — UI layer: real WKWebView + real dist bundle —
        app.setActivationPolicy(.regular)
        let webCfg = WKWebViewConfiguration()
        let sink = ProbeSink()
        webCfg.userContentController.add(sink, name: "goty")
        let webView = WKWebView(frame: NSRect(x: 100, y: 100, width: 900, height: 700), configuration: webCfg)
        let win = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = webView
        win.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        let dist = FileManager.default.currentDirectoryPath + "/swift-app/agent-web/dist/index.html"
        webView.loadFileURL(URL(fileURLWithPath: dist),
                            allowingReadAccessTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        guard pump(until: { ProbeSink.ready }, timeout: 15) else {
            print("FATAL: page never signalled ready"); exit(1)
        }
        func read(_ js: String, label: String) {
            var out: String?
            webView.evaluateJavaScript(js) { r, e in out = e.map { "ERR \($0)" } ?? (r.map { "\($0)" } ?? "nil") }
            _ = pump(until: { out != nil }, timeout: 10)
            print("\(label):", out ?? "nil")
        }
        read("window.__errs = []; window.onerror = function(m){ window.__errs.push(String(m)); }; 1", label: "diag-install")
        read("window.__gotyStore.apply({type:'turnEnded'}); window.__gotyStore.blocks.length", label: "direct-apply")
        read("window.__raf = 0; requestAnimationFrame(() => window.__raf++); 'raf-armed'", label: "raf-arm")
        var raf: String?
        webView.evaluateJavaScript("window.__raf") { r, _ in raf = r.map { "\($0)" } }
        _ = pump(until: { raf != nil }, timeout: 10)
        pump(until: { false }, timeout: 1)
        webView.evaluateJavaScript("window.__raf") { r, _ in raf = r.map { "\($0)" } }
        _ = pump(until: { raf != nil }, timeout: 10)
        print("raf-fired:", raf ?? "nil")
        read("window.__goty.push([{type:'turnEnded'}]); 'pushed'", label: "tiny-push")
        read("window.__gotyStore.blocks.length", label: "blocks-after-tiny")
        read("JSON.stringify(window.__errs)", label: "page-errors")
        // read back store state
        var readBack: String?
        webView.evaluateJavaScript(#"JSON.stringify({blocks: window.__gotyStore.blocks.length, users: window.__gotyStore.blocks.filter(b => b.kind === "user").length, tailKind: window.__gotyStore.blocks[window.__gotyStore.blocks.length-1]?.kind ?? "none"})"#) { result, _ in
            readBack = result as? String
        }
        _ = pump(until: { readBack != nil }, timeout: 30)
        print("STORE after one-shot:", readBack ?? "nil")
        // — empirical threshold sweep: how big may ONE push be? —
        for bytes in [32_000, 64_000, 96_000, 128_000, 160_000, 192_000, 256_000, 512_000] {
            var evs: [[String: Any]] = []
            var total = 0
            while total < bytes {
                evs.append(["type": "agentChunk", "text": String(repeating: "x", count: 400)])
                total += 420
            }
            var donePush = false
            let payload2 = try! String(data: JSONSerialization.data(withJSONObject: evs), encoding: .utf8)!
            webView.evaluateJavaScript("window.__goty.push(\(payload2))") { _, err in
                if let err { print("SWEEP ERROR @\(bytes):", err) }
                donePush = true
            }
            _ = pump(until: { donePush }, timeout: 30)
            pump(until: { false }, timeout: 1)
            var count = -1
            webView.evaluateJavaScript("window.__gotyStore.blocks.length") { r, _ in count = (r as? Int) ?? -1 }
            _ = pump(until: { count >= 0 }, timeout: 10)
            print("sweep \(bytes)B -> total blocks:", count)
        }
        session.shutdown()
        exit(0)
    }
}

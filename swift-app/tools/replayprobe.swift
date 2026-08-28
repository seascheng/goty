// goty — see CLAUDE.md for the working principles.
// End-to-end diagnostic: real Core chain (sessiond + PTY + ACPClient +
// AgentSession) → real AgentWebBridge → real WKWebView running the real
// dist bundle. Runs session/load on the newest persisted omp session and
// reads the store back. If blocks land short of the delegate event count,
// the production transport loses them; if they match, the loss is above.
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
    var mapped: [[String: Any]] = []
    weak var bridge: AgentWebBridge?

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
            if let bridge, let js = jsEvent(e), !js.isEmpty {
                bridge.push(js)
            }
        }
    }

    /// Mirrors AgentPaneHost.jsEvent — keep in sync when editing that.
    private func jsEvent(_ event: AgentSessionEvent) -> [String: Any]? {
        switch event {
        case .ready: return nil
        case .userChunk(let text): return ["type": "userChunk", "text": text]
        case .messageChunk(let text): return ["type": "agentChunk", "text": text]
        case .thoughtChunk(let text): return ["type": "thoughtChunk", "text": text]
        case .toolCallUpdate(let id, let title, let kind, let status, let content, let rawInput, let oldText):
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
            return d
        case .plan(let entries):
            return ["type": "plan", "entries": entries.map { ["content": $0.content, "priority": $0.priority ?? NSNull(), "status": $0.status ?? NSNull()] as [String: Any] }]
        case .permissionRequested(let prompt):
            return ["type": "permission", "requestID": prompt.requestID,
                    "toolCallTitle": prompt.toolCallTitle ?? NSNull(),
                    "options": prompt.options.map { ["optionId": $0.optionId, "name": $0.name, "kind": $0.kind ?? NSNull()] as [String: Any] }]
        case .turnEnded(let stopReason):
            _ = stopReason
            return ["type": "turnEnded"]
        case .configChanged(let opts):
            return ["type": "configOptions", "options": opts.map { ["id": $0.id, "name": $0.name] }]
        case .commandsChanged(let cmds):
            return ["type": "commands", "commands": cmds.map { ["name": $0.name, "description": $0.description ?? "", "input": ["hint": $0.inputHint ?? ""] as [String: String] ] as [String: Any] }]
        case .usageUpdate(let used, let size, let input, let output, let amount, let currency):
            return ["type": "usage", "used": used ?? NSNull(), "size": size ?? NSNull(),
                    "input": input ?? NSNull(), "output": output ?? NSNull(),
                    "costAmount": amount ?? NSNull(), "costCurrency": currency ?? NSNull()]
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
        app.setActivationPolicy(.regular)

        let delegate = ProbeDelegate()
        let session = AgentSession(
            paneId: "replayprobe-\(Int(Date().timeIntervalSince1970))",
            cwd: "/Users/seascheng/Downloads/ai_project/goty-agent-gui",
            grid: SessionGrid(columns: 120, rows: 40, cellWidth: 7, cellHeight: 17),
            environment: ProcessInfo.processInfo.environment.filter { $0.key != "GOTY_AUTOLOAD_SESSION" },
            launch: AgentManifests.acpLaunch(for: "omp")!,
            daemon: .shared,
            delegate: delegate)

        // Web layer first so the bridge can push live during the replay.
        let webCfg = WKWebViewConfiguration()
        let webView = WKWebView(frame: NSRect(x: 100, y: 100, width: 900, height: 700), configuration: webCfg)
        let win = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = webView
        win.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        let dist = FileManager.default.currentDirectoryPath + "/swift-app/agent-web/dist/index.html"
        webView.loadFileURL(URL(fileURLWithPath: dist),
                            allowingReadAccessTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        let bridge = AgentWebBridge(webView: webView)
        delegate.bridge = bridge
        var bridgeReady = false
        bridge.onReady = { bridgeReady = true }
        guard pump(until: { bridgeReady }, timeout: 15) else {
            print("FATAL: page never signalled ready"); exit(1)
        }
        print("page ready")

        var connectOk = false
        session.connect { ok in connectOk = ok }
        guard pump(until: { connectOk }, timeout: 30) else { print("FATAL: connect"); exit(1) }

        var listed: [ACPSessionSummary]?
        session.listSessions { list in listed = list }
        guard pump(until: { listed != nil }, timeout: 30), let sid = listed?.first?.sessionId else {
            print("FATAL: no sessions"); exit(1)
        }
        print("loading:", sid)

        let t0 = Date()
        var loadOk = false
        session.load(sessionId: sid) { ok in loadOk = ok }
        _ = pump(until: { loadOk }, timeout: 60)
        print("load ok:", loadOk, "in", Date().timeIntervalSince(t0), "s")
        pump(until: { false }, timeout: 5)

        delegate.lock.lock()
        print("EVENTS:", delegate.eventCounts.sorted { $0.key < $1.key })
        print("AGENT TAIL:", delegate.lastAgentText.suffix(120))
        delegate.lock.unlock()

        var readBack: String?
        webView.evaluateJavaScript("""
            JSON.stringify({
              revision: window.__gotyStore.revision,
              blocks: window.__gotyStore.blocks.length,
              users: window.__gotyStore.blocks.filter(b => b.kind === 'user').length,
              lastUser: (() => { const u = [...window.__gotyStore.blocks].reverse().find(b => b.kind === 'user'); return u ? u.text.slice(0, 80) : null; })(),
              tailKind: window.__gotyStore.blocks[window.__gotyStore.blocks.length-1]?.kind ?? 'none',
              tailText: ((window.__gotyStore.blocks[window.__gotyStore.blocks.length-1]?.text) ?? '').slice(-120),
            })
            """) { r, err in
            if let err { print("READ ERROR:", err) }
            readBack = r as? String
        }
        _ = pump(until: { readBack != nil }, timeout: 30)
        print("STORE:", readBack ?? "nil")
        session.shutdown()
        exit(0)
    }
}

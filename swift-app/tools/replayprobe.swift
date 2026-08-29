// goty — see CLAUDE.md for the working principles.
// End-to-end diagnostic: real Core chain (sessiond + PTY + JSONRPCChannel +
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
    var lastUserText = ""
    var lastAgentText = ""
    var lastThoughtText = ""
    /// Latest-wins per tool id — mirrors the page store's upsert so the
    /// char totals are comparable across the boundary.
    var toolContentChars: [String: Int] = [:]
    var toolOutputChars: [String: Int] = [:]
    var totalEvents = 0
    weak var bridge: AgentWebBridge?

    func session(_ session: AgentSession, didEmit events: [AgentSessionEvent]) {
        lock.lock(); defer { lock.unlock() }
        totalEvents += events.count
        for e in events {
            switch e {
            case .ready: break
            case .userChunk(let t):
                eventCounts["userChunk", default: 0] += 1
                lastUserText += t
            case .messageChunk(let t):
                eventCounts["messageChunk", default: 0] += 1
                lastAgentText += t
            case .thoughtChunk(let t):
                eventCounts["thoughtChunk", default: 0] += 1
                lastThoughtText += t
            case .toolCallUpdate(let id, _, _, _, let content, let output, _, _):
                eventCounts["toolCallUpdate", default: 0] += 1
                toolContentChars[id] = content.reduce(0) { $0 + ($1.text?.utf16.count ?? 0) }
                toolOutputChars[id] = output.reduce(0) { $0 + ($1.text?.utf16.count ?? 0) }
            case .plan: eventCounts["plan", default: 0] += 1
            case .permissionRequested: eventCounts["permission", default: 0] += 1
            case .turnEnded: eventCounts["turnEnded", default: 0] += 1
            case .configChanged: eventCounts["config", default: 0] += 1
            case .commandsChanged: eventCounts["commands", default: 0] += 1
            case .usageUpdate: eventCounts["usage", default: 0] += 1
            }
            if let bridge {
                bridge.push(e.jsRepresentation)
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
        pump(until: { false }, timeout: 8)

        delegate.lock.lock()
        print("EVENTS:", delegate.eventCounts.sorted { $0.key < $1.key })
        print("AGENT TAIL:", delegate.lastAgentText.suffix(120))
        let swiftEvents = delegate.totalEvents
        let swiftUser = delegate.lastUserText
        let swiftAgent = delegate.lastAgentText
        let swiftThought = delegate.lastThoughtText
        let swiftToolChars = delegate.toolContentChars.values.reduce(0, +)
            + delegate.toolOutputChars.values.reduce(0, +)
        delegate.lock.unlock()

        // — Integrity audit: every layer must agree byte-for-byte —
        var audit: String?
        webView.evaluateJavaScript("""
            JSON.stringify({
              applied: window.__gotyStore.appliedCount,
              rejected: window.__gotyStore.rejectedCount,
              userText: window.__gotyStore.blocks.filter(b => b.kind === 'user').map(b => b.text).join(''),
              agentText: window.__gotyStore.blocks.filter(b => b.kind === 'agent').map(b => b.text).join(''),
              thoughtText: window.__gotyStore.blocks.filter(b => b.kind === 'thought').map(b => b.text).join(''),
              toolChars: [...window.__gotyStore.tools.values()].reduce((n, c) =>
                n + c.content.reduce((m, x) => m + (x.text ? x.text.length : 0), 0)
                  + c.output.reduce((m, x) => m + (x.text ? x.text.length : 0), 0), 0),
            })
            """) { r, err in
            if let err { print("READ ERROR:", err) }
            audit = r as? String
        }
        _ = pump(until: { audit != nil }, timeout: 30)
        guard let raw = audit,
              let data = raw.data(using: .utf8),
              let page = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("FAIL  page audit readback")
            exit(1)
        }
        let pageApplied = page["applied"] as? Int ?? -1
        let pageRejected = page["rejected"] as? Int ?? -1
        let pageToolChars = page["toolChars"] as? Int ?? -1
        print("PAGE: applied=\(pageApplied) rejected=\(pageRejected) toolChars=\(pageToolChars)")

        var auditFailures = 0
        func expect(_ ok: Bool, _ name: String) {
            if ok { print("  ok  \(name)") } else { auditFailures += 1; print("FAIL  \(name)") }
        }
        expect(bridge.droppedPoison == 0, "bridge dropped no poison events")
        expect(swiftEvents == bridge.pushed,
               "delegate events == bridge pushed (\(swiftEvents) vs \(bridge.pushed))")
        expect(pageRejected == 0, "page rejected nothing")
        expect(pageApplied + pageRejected == bridge.delivered,
               "page applied+rejected == bridge delivered (\(pageApplied)+\(pageRejected) vs \(bridge.delivered))")
        expect(page["userText"] as? String == swiftUser, "user text byte-equal")
        expect(page["agentText"] as? String == swiftAgent, "agent text byte-equal")
        expect(page["thoughtText"] as? String == swiftThought, "thought text byte-equal")
        expect(pageToolChars == swiftToolChars,
               "tool text chars byte-equal (\(pageToolChars) vs \(swiftToolChars))")

        session.shutdown()
        if auditFailures > 0 { exit(1) }
        print("replayprobe: integrity audit passed")
        exit(0)
    }
}

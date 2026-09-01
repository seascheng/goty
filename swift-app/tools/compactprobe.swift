// compactprobe.swift — end-to-end /compact probe through the REAL Core
// chain: OmpSession (spawn via sessiond) → handshake → poll → send
// "/compact" → count runtimeStatus(compacting) events. This exercises
// exactly the path the GUI drives, including the off-main connect()
// change and the 2s state poll.
//
// Build like run-tests.sh builds replayprobe; run from repo root:
//   ./goty-compactprobe
import Foundation
import AppKit
@testable import goty

final class CompactDelegate: NSObject, AgentSessionDelegate {
    let lock = NSLock()
    var runtimeEvents = 0
    var compactingEvents = 0
    var compactingFalseEvents = 0
    var notices: [String] = []
    var turnEnded = 0
    var commands = 0
    var configEvents = 0
    var failed: String?

    func session(_ session: AgentSessioning, didEmit events: [AgentSessionEvent]) {
        lock.lock(); defer { lock.unlock() }
        for e in events {
            switch e {
            case .runtimeStatus(let s):
                runtimeEvents += 1
                if s.isCompacting == true { compactingEvents += 1 }
                if s.isCompacting == false { compactingFalseEvents += 1 }
            case .notice(let t): notices.append(t)
            case .turnEnded: turnEnded += 1
            case .commandsChanged: commands += 1
            case .configChanged: configEvents += 1
            default: break
            }
        }
    }

    func sessionDidFail(_ session: AgentSessioning, reason: String) {
        lock.lock(); defer { lock.unlock() }
        failed = reason
    }
}

@main
enum CompactProbe {
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

        let delegate = CompactDelegate()
        // Fresh spawn (no resume): small session compaction fails fast
        // with a command_output — the point is the EVENT plumbing, and
        // fresh spawn is what the GUI does on a new pane.
        let session = OmpSession(
            params: AgentPaneParams(
                paneId: "compactprobe-\(Int(Date().timeIntervalSince1970))",
                cwd: "/tmp",
                environment: ProcessInfo.processInfo.environment,
                daemon: .shared))
        session.delegate = delegate

        var connectOk = false
        session.connect { ok in connectOk = ok }
        guard pump(until: { connectOk || delegate.failed != nil }, timeout: 60) else {
            print("FATAL: connect timed out"); exit(1)
        }
        if let f = delegate.failed { print("FATAL: connect failed: \(f)"); exit(1) }
        print("connected: \(connectOk)")
        // let a few poll cycles land
        _ = pump(until: { false }, timeout: 5)

        delegate.lock.lock()
        let base = (runtime: delegate.runtimeEvents, compactingTrue: delegate.compactingEvents,
                    turnEnded: delegate.turnEnded, commands: delegate.commands,
                    config: delegate.configEvents)
        delegate.lock.unlock()
        print("baseline: \(base)")

        // THE /compact send — the exact GUI path.
        session.send("/compact")
        print("sent /compact at \(Date())")

        // Watch up to 20s for: runtimeStatus.compacting=true, or a
        // notice carrying the failure text, or turnEnded (heal).
        var sawCompacting = false
        var sawNoticeOrEnd = false
        _ = pump(until: {
            delegate.lock.lock(); defer { delegate.lock.unlock() }
            sawCompacting = sawCompacting || delegate.compactingEvents > 0
            sawNoticeOrEnd = sawNoticeOrEnd || !delegate.notices.isEmpty || delegate.turnEnded > 0
            return sawCompacting || sawNoticeOrEnd
        }, timeout: 20)

        _ = pump(until: { false }, timeout: 6)
        delegate.lock.lock()
        print("RESULT runtimeEvents=\(delegate.runtimeEvents) " +
              "compactingTrue=\(delegate.compactingEvents) " +
              "compactingFalse=\(delegate.compactingFalseEvents) " +
              "turnEnded=\(delegate.turnEnded) commands=\(delegate.commands)")
        print("notices: \(delegate.notices)")
        if let f = delegate.failed { print("sessionDidFail: \(f)") }
        delegate.lock.unlock()
        print(sawCompacting ? "VERDICT: compacting observed" :
              (sawNoticeOrEnd ? "VERDICT: no compacting status — failure surfaced another way"
                              : "VERDICT: NOTHING observed — /compact is a silent no-op"))
        session.shutdown()
        exit(0)
    }
}

// piprobetest.swift — TEMPORARY live probe (not committed): mid-turn attach.
// Verifies: attach onto a streaming turn keeps working state, history
// renders through the gate, and the settle rebuild heals the in-flight
// message's pre-attach deltas with zero permanent loss.
import AppKit
@testable import goty

@main
enum PiProbeTest {
    static func main() {
        final class Probe: AgentSessionDelegate {
            var resets = 0
            var userHits = 0
            var assistantChars = 0
            var postAttachChunks = 0
            func session(_ s: AgentSessioning, didEmit events: [AgentSessionEvent]) {
                for e in events {
                    switch e {
                    case .transcriptReset: resets += 1
                        print("PROBE transcriptReset #\(resets)")
                    case .userMessage(let t) where t.contains("PROBE_MARKER"):
                        userHits += 1
                        print("PROBE history user hit #\(userHits)")
                    case .messageChunk(let t):
                        assistantChars += t.count
                        postAttachChunks += 1
                    case .turnEnded:
                        print("PROBE turnEnded (total assistant chars so far: \(assistantChars))")
                    case .error(let text): print("PROBE error \(text)")
                    default: break
                    }
                }
            }
            func sessionDidFail(_ s: AgentSessioning, reason: String) {
                print("PROBE FAIL \(reason)")
            }
        }
        try? FileManager.default.createDirectory(atPath: "/tmp/probe-pi3",
                                                 withIntermediateDirectories: true)
        let session = PiLegacySession(params: AgentPaneParams(
            paneId: "probe-" + UUID().uuidString.prefix(8),
            cwd: "/tmp/probe-pi3",
            environment: ProcessInfo.processInfo.environment,
            daemon: .shared, restoredSessionId: nil))
        let probe = Probe()
        session.delegate = probe
        session.connect { ok in
            print("PROBE connect ok=\(ok)")
            // Long generation so the turn is still streaming at reconnect.
            session.send("PROBE_MARKER: Write a detailed 2000-word technical essay "
                + "about distributed consensus, with examples.", images: [])
        }
        // Reconnect ~8s in, while the essay is still streaming.
        RunLoop.main.run(until: Date().addingTimeInterval(8))
        let streamingAtReconnect = session.isWorking
        print("PROBE reconnect mid-turn (isWorking=\(streamingAtReconnect))…")
        session.reconnect { ok in
            print("PROBE reconnect ok=\(ok)")
        }
        // Wait for the turn to settle + the 1.5s-delayed rebuild.
        RunLoop.main.run(until: Date().addingTimeInterval(70))
        print("PROBE summary resets=\(probe.resets) userHits=\(probe.userHits) "
            + "assistantChars=\(probe.assistantChars) chunks=\(probe.postAttachChunks)")
        // Passes when: mid-turn state adopted, history rendered twice
        // (attach gate + settle rebuild), and the healed transcript
        // carries a full essay's worth of text.
        let ok = streamingAtReconnect && probe.resets >= 2 && probe.userHits >= 2
            && probe.assistantChars > 4000
        print("PROBE VERDICT mid-turn-attach: \(ok ? "OK" : "BROKEN)")
        exit(ok ? 0 : 1)
    }
}

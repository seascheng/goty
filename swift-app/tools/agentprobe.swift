// goty — see CLAUDE.md for the working principles.
// E2E probe: one agent family, real CLI, real sessiond pane, real
// adapter — the same chain the GUI runs. Two modes:
//   agentprobe <key> live                    connect → prompt → turn ends
//   agentprobe <key> resume <sid> <marker>   load → history replayed
// PROBE_EXPECT_MARKER=1 additionally requires the model's reply text
// to carry the marker (live mode; a broken model backend still proves
// the protocol chain without it). Exit 0 = assertions held. One-off
// pane ids; never touches GUI panes.
import Foundation
@testable import goty

@main
enum AgentProbe {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            print("usage: agentprobe <omp|claude|codex|pi> live|reattach|resume [sid marker]")
            exit(2)
        }
        let key = args[1]
        let mode = args[2]
        guard let descriptor = AgentRegistry.descriptor(for: key) else {
            print("FATAL: no descriptor for \(key)")
            exit(2)
        }

        final class Collector: AgentSessionDelegate {
            var ready = false
            var chunks: [String] = []
            var userChunks: [String] = []
            var turnsEnded = 0
            var failure: String?
            func session(_ s: AgentSessioning, didEmit events: [AgentSessionEvent]) {
                DispatchQueue.main.async {
                    for event in events {
                        switch event {
                        case .ready:
                            self.ready = true
                            print("PROBE  ready")
                        case .messageChunk(let text):
                            self.chunks.append(text)
                        case .userChunk(let text):
                            self.userChunks.append(text)
                            print("PROBE  userChunk (\(text.count)B)")
                        case .turnEnded:
                            self.turnsEnded += 1
                            print("PROBE  turnEnded #\(self.turnsEnded)")
                        case .commandsChanged(let commands):
                            print("PROBE  commands=\(commands.count) first=\(commands.first?.name ?? "none")")
                        default:
                            break
                        }
                    }
                }
            }
            func sessionDidFail(_ s: AgentSessioning, reason: String) {
                DispatchQueue.main.async {
                    self.failure = reason
                    print("PROBE  sessionDidFail: \(reason)")
                }
            }
        }

        let collector = Collector()
        let paneId = "probe-\(key)-\(UUID().uuidString.prefix(8))"
        let session = descriptor.make(AgentPaneParams(
            paneId: paneId,
            cwd: "/tmp/probe-cwd",
            environment: UserShellEnv.asDictionary,
            daemon: .shared))
        session.delegate = collector

        var failures = 0
        func check(_ ok: Bool, _ label: String) {
            if ok {
                print("  ok  \(label)")
            } else {
                failures += 1
                print("  FAIL  \(label)")
            }
        }
        func conclude() -> Never {
            print(failures == 0 ? "PROBE PASS" : "PROBE FAIL")
            exit(failures == 0 ? 0 : 1)
        }
        func pump(_ seconds: TimeInterval) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                if mode == "live" || mode == "reattach",
                   collector.turnsEnded > 0 || collector.failure != nil {
                    break
                }
            }
        }

        let env = ProcessInfo.processInfo.environment
        let prompt = "Reply with exactly HELLO_\(key.uppercased()) and nothing else"

        session.connect { ok in
            DispatchQueue.main.async {
                print("PROBE  connect ok=\(ok)")
                switch mode {
                case "live":
                    session.send(prompt)
                case "reattach":
                    // The keep/recover contract, end to end: detach the
                    // transport (the daemon keeps the pane + its live
                    // process), reattach, adopt the session from the ring
                    // replay, then keep working on the SAME session.
                    let sessionBefore = session.sessionId
                    session.reconnect { ok2 in
                        DispatchQueue.main.async {
                            print("PROBE  reconnect ok=\(ok2)")
                            check(ok2, "reattach reopens the transport")
                            // sessionId is re-learned from the replayed
                            // orphan response — wait for the ring bytes.
                            let deadline = Date().addingTimeInterval(15)
                            while session.sessionId == nil, Date() < deadline {
                                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                            }
                            check(session.sessionId == sessionBefore,
                                  "reattach adopts the SAME live session id (before=\(sessionBefore ?? "nil") after=\(session.sessionId ?? "nil"))")
                            // The attach auto-load replays the AUTHORITATIVE
                            // history — turn 1's user prompt must come back
                            // (the ring alone never carries user prompts).
                            let loadDeadline = Date().addingTimeInterval(25)
                            while !collector.userChunks.contains(where: { $0.contains("HELLO_") }),
                                  Date() < loadDeadline {
                                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                            }
                            check(collector.userChunks.contains(where: { $0.contains("HELLO_") }),
                                  "reattach auto-load restores the user's own prompt")
                            session.send(prompt)
                        }
                    }
                case "resume" where args.count >= 5:
                    let sid = args[3]
                    let marker = args[4]
                    print("PROBE  loading \(sid)")
                    session.load(sessionId: sid) { loaded in
                        DispatchQueue.main.async {
                            print("PROBE  load ok=\(loaded)")
                            let replayOK = collector.userChunks.contains {
                                $0.contains(marker)
                            }
                            check(loaded && replayOK,
                                  "resume replay carries marker in user turn")
                            conclude()
                        }
                    }
                default:
                    print("FATAL: resume needs <sid> <marker>")
                    exit(2)
                }
            }
        }

        if mode == "live" || mode == "reattach" {
            pump(200)
            check(collector.ready, "\(key) reached ready")
            check(collector.turnsEnded > 0 || collector.failure != nil,
                  "\(key) turn concluded")
            let text = collector.chunks.joined()
            print("PROBE  assembled (\(text.count)B): \(String(text.prefix(300)))")
            if collector.failure == nil {
                let modelOK = text.uppercased().contains("HELLO_\(key.uppercased())")
                if env["PROBE_EXPECT_MARKER"] == "1" {
                    check(modelOK, "\(key) replied with the marker")
                } else {
                    print(modelOK ? "  ok  marker present"
                                  : "  note  marker absent (model backend state)")
                }
            }
            conclude()
        }

        // resume mode: the load completion above concludes the probe.
        pump(240)
        print("PROBE FAIL  resume did not conclude")
        exit(1)
    }
}

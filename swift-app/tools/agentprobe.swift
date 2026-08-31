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
                            print("PROBE  msg \(text.count)B: \(text.prefix(40).replacingOccurrences(of: "\n", with: "⏎"))")
                        case .thoughtChunk(let text):
                            print("PROBE  think \(text.count)B: \(text.prefix(40).replacingOccurrences(of: "\n", with: "⏎"))")
                        case .toolCallUpdate(let id, let title, _, let status, _, _, _, _):
                            print("PROBE  tool \(status ?? "?") \(title ?? "?") \(id.prefix(6))")
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
            // The daemon keeps panes alive by design; a probe that exits
            // without killing its pane leaks an omp process forever (36
            // accumulated before this cleanup existed).
            SessionDaemon.shared.killPane(id: paneId)
            exit(failures == 0 ? 0 : 1)
        }
        func pump(_ seconds: TimeInterval) {
            // reattach runs TWO turns (history first, then post-reconnect
            // continuation) — a single-turn break would cut the probe off
            // while the reconnect verification is still in flight.
            let turnsNeeded = mode == "reattach" ? 2 : 1
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                if mode == "live" || mode == "reattach",
                   collector.turnsEnded >= turnsNeeded || collector.failure != nil {
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
                case "idle":
                    // Fresh-pane contract: ready must come from the
                    // SPAWN (claude emits nothing before the first user
                    // turn in SDK mode — waiting for init tripped the
                    // 90s watchdog with claude healthy). No send here.
                    let deadline = Date().addingTimeInterval(25)
                    while !collector.ready && collector.failure == nil,
                          Date() < deadline {
                        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                    }
                    check(collector.ready, "\(key) reaches ready WITHOUT any user turn")
                    conclude()
                case "live":
                    session.send(prompt)
                case "reattach":
                    // Turn 1 FIRST: keep/recover only means something
                    // with history to keep. The reconnect below must
                    // preserve the session id and restore this prompt
                    // via the respawn's session/load replay.
                    session.send(prompt)
                    let turnDeadline = Date().addingTimeInterval(120)
                    while collector.turnsEnded < 1 && collector.failure == nil,
                          Date() < turnDeadline {
                        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                    }
                    check(collector.turnsEnded >= 1, "turn 1 concluded before reattach")
                    let sessionBefore = session.sessionId
                    session.reconnect { ok2 in
                        DispatchQueue.main.async {
                            print("PROBE  reconnect ok=\(ok2)")
                            check(ok2, "reattach reopens the transport")
                            // sessionId survives via the respawn's
                            // session/load — wait for its completion.
                            let deadline = Date().addingTimeInterval(15)
                            while session.sessionId == nil, Date() < deadline {
                                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                            }
                            check(session.sessionId == sessionBefore,
                                  "reattach adopts the SAME live session id (before=\(sessionBefore ?? "nil") after=\(session.sessionId ?? "nil"))")
                            // The respawn's session/load replays the
                            // AUTHORITATIVE history — turn 1's user prompt
                            // must come back (the ring alone never carries
                            // user prompts).
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

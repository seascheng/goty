// agenttest.swift — headless contract tests for Core/Agent (ACP).
//
// Built and run by run-tests.sh; NOT part of the app binary.
import Foundation
@testable import goty

@main
enum AgentTest {
    static func main() {
        var failures = 0
        func check(_ cond: Bool, _ name: String) {
            if cond { print("  ok  \(name)") } else { failures += 1; print("FAIL  \(name)") }
        }

        print("— agentSpawnPayload —")
        let grid = SessionGrid(columns: 120, rows: 40, cellWidth: 8, cellHeight: 16)
        let payload = SessionDaemon.agentSpawnPayload(
            cwd: "/tmp", shell: "omp", args: ["acp"],
            environment: ["PATH": "/usr/bin"], grid: grid,
            noEcho: true, ringBytes: 67_108_864)
        check(payload["no_echo"] as? Bool == true, "no_echo=true present")
        check(payload["ring_bytes"] as? UInt64 == 67_108_864, "ring_bytes present")
        check((payload["args"] as? [String]) == ["acp"], "args pass through")
        check((payload["env"] as? [[String]]) == [["PATH", "/usr/bin"]], "env pairs")
        let plain = SessionDaemon.agentSpawnPayload(
            cwd: nil, shell: "/bin/zsh", args: ["-l"], environment: [:],
            grid: grid, noEcho: false, ringBytes: nil)
        check(plain["no_echo"] == nil && plain["ring_bytes"] == nil,
              "terminal panes serialize without the new keys")
        // The size dict is protocol.rs's WinSize: all four fields are
        // REQUIRED on the daemon side — a partial dict fails its serde
        // and every spawn (terminal and agent alike) comes back ERROR.
        check((plain["size"] as? [String: UInt16])
                  == ["cols": 120, "rows": 40, "cell_w": 8, "cell_h": 16],
              "size carries the full WinSize contract (cols/rows/cell_w/cell_h)")

        print("— NdjsonSplitter —")
        var splitter = NdjsonSplitter()
        check(splitter.feed(Array("{\"a\":1}\n".utf8)) == ["{\"a\":1}"], "single line")
        check(splitter.feed(Array("{\"b\"".utf8)).isEmpty, "partial line buffered")
        check(splitter.feed(Array("}\n{\"c\":3}\n".utf8)) == ["{\"b\"}", "{\"c\":3}"],
              "split across chunks")
        check(splitter.feed(Array("x\r\ny\n".utf8)) == ["x", "y"], "CRLF trimmed")

        print("— starting phase —")
        let startingJS = AgentSessionEvent.starting(agent: "Claude Code").jsRepresentation
        check(startingJS["type"] as? String == "starting"
              && startingJS["agent"] as? String == "Claude Code",
              "starting event maps to JS shape")
        let resetJS = AgentSessionEvent.transcriptReset.jsRepresentation
        check(resetJS["type"] as? String == "clearTranscript",
              "transcriptReset maps to the store's clearTranscript")

        print("— JSONRPCChannel echo filter + routing —")
        let client = JSONRPCChannel()
        var notifications: [(String, [String: Any])] = []
        client.onNotification = { notifications.append(($0, $1)) }
        // Mirror the codex adapter: answer server requests synchronously
        // — the deadlock shape (respond inside feed's callback) must hold.
        client.onRequest = { id, _, _ in client.respond(id: id, result: [:]) }
        var outbound: [[UInt8]] = []
        client.onOutbound = { outbound.append($0) }
        var got: Result<[String: Any], RPCFailure>?
        client.request("initialize", ["protocolVersion": 1]) { got = $0 }
        let sentLine = String(decoding: outbound[0], as: UTF8.self)
        let routedBefore = client.messagesRouted
        // stty 竞态窗口的回显：逐字节原样回来（PTY 会加 \r），必须被
        // 丢弃——不解码成服务器请求、不触发应答、不碰 pending。
        client.feed(Array(sentLine.replacingOccurrences(of: "\n", with: "\r\n").utf8))
        check(client.messagesRouted == routedBefore && notifications.isEmpty,
              "echoed request dropped (CRLF form)")
        check(got == nil, "echo does not complete the pending request")
        client.feed(Array("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":1}}\n".utf8))
        var completed = false
        if case .success? = got { completed = true }
        check(completed, "pending request completed")
        client.notify("session/cancel", ["sessionId": "s1"])
        client.feed(Array("{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"s1\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"hi\"}}}}\n".utf8))
        check(notifications.count == 1 && notifications[0].0 == "session/update",
              "notification routed")

        // Edit-snapshot fixture: the interpret path reads this file from disk.
        let samplePath = "/tmp/goty-agenttest-sample.txt"
        try? "old content".write(toFile: samplePath, atomically: true, encoding: .utf8)

        print("— PiFrameMapper (omp rpc) —")
        var events: [AgentSessionEvent] = []
        let rpcMapper = PiFrameMapper(terminalOnAgentEnd: true)

        // Live delta stream (message_update.assistantMessageEvent).
        events += rpcMapper.map(["type": "message_update", "assistantMessageEvent": [
            "type": "text_delta", "delta": "hello"]])
        events += rpcMapper.map(["type": "message_update", "assistantMessageEvent": [
            "type": "thinking_delta", "delta": "pondering"]])
        check(events.count == 2, "two events so far")
        if case .messageChunk(let text)? = events.first, text == "hello" {} else {
            failures += 1; print("FAIL  messageChunk payload")
        }
        if case .thoughtChunk(let think)? = events.last, think == "pondering" {} else {
            failures += 1; print("FAIL  thoughtChunk payload")
        }

        // omp tool lifecycle frames (probed 18.0.10).
        events += rpcMapper.map(["type": "tool_execution_start",
                                 "toolCallId": "t1", "toolName": "bash",
                                 "args": ["command": "ls -la"],
                                 "intent": "Listing files"])
        if case .toolCallUpdate(let id, let title, _, let status, let content, _, _, _)? = events.last,
           id == "t1", title == "Listing files", status == "in_progress",
           content.first?.text == "ls -la" {} else {
            failures += 1; print("FAIL  tool_execution_start payload")
        }
        events += rpcMapper.map(["type": "tool_execution_update",
                                 "toolCallId": "t1", "toolName": "bash",
                                 "args": ["command": "ls -la"],
                                 "partialResult": ["content":
                                    [["type": "text", "text": "partial body"]]]])
        if case .toolCallUpdate(_, _, _, let status, _, let output, _, _)? = events.last,
           status == "in_progress", output.first?.text == "partial body" {} else {
            failures += 1; print("FAIL  tool_execution_update partial output")
        }
        events += rpcMapper.map(["type": "tool_execution_end",
                                 "toolCallId": "t1", "toolName": "bash",
                                 "result": ["content":
                                    [["type": "text", "text": "tool result body"]]],
                                 "isError": false])
        if case .toolCallUpdate(_, _, _, let status, _, let output, _, _)? = events.last,
           status == "completed", output.first?.text == "tool result body" {} else {
            failures += 1; print("FAIL  tool_execution_end payload")
        }
        // The end frame is terminal for the call: a duplicate end must
        // not re-emit (omp may redeliver on retry paths).
        let before = events.count
        events += rpcMapper.map(["type": "tool_execution_end",
                                 "toolCallId": "t1", "toolName": "bash",
                                 "result": ["content": [["type": "text", "text": "dup"]]],
                                 "isError": false])
        check(events.count == before, "duplicate tool end deduped")

        // User echo: suppressed live, emitted in replay mode (a
        // reattached page rebuilds the user side from the ring).
        let userFrame: [String: Any] = ["type": "message_end", "message": [
            "role": "user",
            "content": [["type": "text", "text": "我看当前已经有了"]]]]
        events += rpcMapper.map(userFrame)
        check(events.count == before, "live user echo suppressed")
        rpcMapper.replaying = true
        events += rpcMapper.map(userFrame)
        rpcMapper.replaying = false
        if case .userChunk(let userText)? = events.last, userText == "我看当前已经有了" {} else {
            failures += 1; print("FAIL  user echo in replay mode")
        }

        // agent_end: terminal for omp (turnEnded), non-terminal frames
        // (auto-retry boundaries) must not settle the turn.
        events += rpcMapper.map(["type": "agent_end", "isTerminal": false])
        if case .turnEnded?? = events.last { failures += 1; print("FAIL  non-terminal agent_end settled the turn") }
        events += rpcMapper.map(["type": "agent_end"])
        if case .turnEnded?? = events.last {} else { failures += 1; print("FAIL  terminal agent_end ends turn") }

        // available_commands_update carries omp's slash commands.
        events += rpcMapper.map(["type": "available_commands_update",
                                 "commands": [["name": "model", "description": "Show current model"],
                                              ["name": "fast", "input": ["hint": "[on|off]"]]]])
        if case .commandsChanged(let commands)? = events.last, commands.count == 2,
           commands[0].name == "model", commands[1].inputHint == "[on|off]" {} else {
            failures += 1; print("FAIL  commands payload")
        }


        print("— ACPContentNormalizer —")
        check(ACPContentNormalizer.flatten([["type": "text", "text": "a"]]).first?.text == "a",
              "flat leaf")
        check(ACPContentNormalizer.flatten([
            ["type": "content", "content": ["type": "text", "text": "inner"]],
        ]).first?.text == "inner", "nested single wrapper")
        check(ACPContentNormalizer.flatten([
            ["type": "content", "content": [["type": "text", "text": "b"],
                                            ["type": "text", "text": "c"]]],
        ]).map { $0.text } == ["b", "c"], "nested list wrapper")
        check(ACPContentNormalizer.resultItems(rawOutput: [
            "content": [["type": "text", "text": "out"]],
        ]).first?.text == "out", "rawOutput content")
        check(ACPContentNormalizer.resultItems(rawOutput: [
            "details": ["displayContent": "display fallback"],
        ]).first?.text == "display fallback", "displayContent fallback")

        print("— NdjsonSplitter big lines —")
        var big = NdjsonSplitter()
        let huge = "{\"j\":\"" + String(repeating: "y", count: 2_000_000) + "\"}\n"
        let raw = Array(huge.utf8)
        var collected: [String] = []
        var idx = 0
        while idx < raw.count {
            let end = min(idx + 7919, raw.count)
            collected += big.feed(Array(raw[idx..<end]))
            idx = end
        }
        check(collected.count == 1 && collected[0].count == huge.count - 1,
              "2MB line survives chunked feed byte-exact")

        print("— JSONRPCChannel replay suppression —")
        let rc = JSONRPCChannel()
        var replayed: [(String, [String: Any])] = []
        var liveResult: [String: Any]?
        var liveDone = false
        rc.onNotification = { replayed.append(($0, $1)) }
        rc.request("session/new", [:]) { result in
            if case .success(let v) = result { liveResult = v }
            liveDone = true
        }
        // Ring history: the OLD session/new response carries the SAME id.
        // It must not complete the fresh handshake…
        rc.feed(Array("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"sessionId\":\"stale\"}}\n".utf8), replay: true)
        check(!liveDone, "replayed stale response does not complete pending")
        // …while history notifications still rebuild the transcript.
        rc.feed(Array("{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"from-ring\"}}}}\n".utf8), replay: true)
        check(replayed.count == 1, "replayed notification routed")
        // The real live response completes normally afterwards.
        rc.feed(Array("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"sessionId\":\"fresh\"}}\n".utf8))
        check(liveDone && liveResult?["sessionId"] as? String == "fresh",
              "live response completes after replay")

        print("— JSONRPCChannel orphan-result capture (attach adoption) —")
        let oc = JSONRPCChannel()
        var orphans: [[String: Any]] = []
        oc.onOrphanResult = { orphans.append($0) }
        // The ring re-streams the pane's FIRST client's session/new
        // response; a reattaching adapter re-learns the live sessionId
        // from exactly this orphan — never re-running the handshake.
        oc.feed(Array("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"sessionId\":\"live-s1\",\"configOptions\":[]}}\n".utf8), replay: true)
        check(orphans.count == 1 && orphans[0]["sessionId"] as? String == "live-s1",
              "replayed response surfaces as orphan result")
        // Live traffic can orphan too (a response outliving its request).
        oc.feed(Array("{\"jsonrpc\":\"2.0\",\"id\":99,\"result\":{\"threadId\":\"t1\"}}\n".utf8))
        check(orphans.count == 2 && orphans[1]["threadId"] as? String == "t1",
              "live unknown-id response surfaces as orphan result")
        // Responses WITH a pending waiter never route to the orphan hook.
        var pendingDone = false
        let oc2 = JSONRPCChannel()
        let pendingID = oc2.request("initialize", [:]) { _ in pendingDone = true }
        oc2.feed(Array("{\"jsonrpc\":\"2.0\",\"id\":\(pendingID),\"result\":{}}\n".utf8))
        check(pendingDone && orphans.count == 2,
              "matched response completes pending, skips orphan hook")

        print("— JSONRPCChannel replayed request surface (user prompt recovery) —")
        let rcPrompt = JSONRPCChannel()
        var promptReplays: [(Int, String, [String: Any])] = []
        rcPrompt.onReplayRequest = { (id: Int, method: String, params: [String: Any]) in
            promptReplays.append((id, method, params))
        }
        // ring_input panes re-stream the user's own session/prompt wire —
        // the reattached adapter rebuilds the user's side of the history
        // from exactly these lines (omp never echoes prompts in updates).
        rcPrompt.feed(Array("{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"live-s1\",\"prompt\":[{\"type\":\"text\",\"text\":\"修复这个bug\"}]}}\n".utf8), replay: true)
        check(promptReplays.count == 1 && promptReplays[0].1 == "session/prompt"
              && (promptReplays[0].2["prompt"] as? [[String: Any]])?.first?["text"] as? String == "修复这个bug",
              "replayed session/prompt surfaces via onReplayRequest")
        // A LIVE prompt request line is this client's own traffic — never
        // surfaced as replay.
        rcPrompt.feed(Array("{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"session/prompt\",\"params\":{}}\n".utf8))
        check(promptReplays.count == 1, "live prompt request does not surface as replay")

        print("— integrity counters —")
        check(rpcMapper.eventsRouted > 0 && rpcMapper.framesIgnored > 0,
              "mapper counts routed and ignored frames")
        check(rc.messagesRouted == 3, "messages routed counted")
        print("— UserShellEnv —")
        // The Finder-launch regression: a non-interactive capture missed
        // .zshrc, agent CLIs got a PATH without them and died instantly.
        // The interactive capture must resolve the real toolchain PATH.
        check(UserShellEnv.asDictionary["PATH"]?.contains("homebrew") == true,
              "captured PATH resolves the user toolchain")
        check(UserShellEnv.asDictionary["HOME"] != nil, "HOME present in merged env")

        print("— registry —")
        let omp = AgentRegistry.descriptor(for: "omp")
        check(omp?.spawn.command == "omp" && omp?.spawn.args == ["--mode", "rpc"], "omp rpc spawn")
        check(omp?.spawn.ringBytes == 67_108_864, "omp uses the 64 MiB ring")
        check(AgentRegistry.descriptors.first?.key == "omp", "picker order leads with omp")
        let path = UserShellEnv.asDictionary["PATH"] ?? ""
        check(omp?.isAvailable(path: path) == true, "omp resolves in captured PATH")

        print("— claude adapter —")
        check(AgentRegistry.descriptor(for: "claude")?.binary == "claude", "claude descriptor present")
        let claudeFixture = (CommandLine.arguments.count > 1
            ? CommandLine.arguments[1] : "tools/fixtures") + "/claude-oneshot.jsonl"
        var claudeEvents: [AgentSessionEvent] = []
        let claudeMapper = ClaudeFrameMapper()
        var claudeLines = 0
        if let lines = try? String(contentsOfFile: claudeFixture, encoding: .utf8) {
            for line in lines.split(separator: "\n") {
                guard let data = String(line).data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data),
                      let frame = json as? [String: Any] else { continue }
                claudeLines += 1
                claudeEvents += claudeMapper.map(frame)
            }
        }
        check(claudeLines == 7, "claude fixture frames counted (\(claudeLines))")
        check(claudeMapper.framesIgnored == 4, "hook lifecycle frames ignored (\(claudeMapper.framesIgnored))")
        check(claudeEvents.contains(where: { if case .ready = $0 { return true }; return false }),
              "init maps ready")
        check(claudeMapper.sessionId == "2123c193-59d5-4165-a29c-80372472a3f0",
              "session id captured")
        check(claudeEvents.contains(where: { if case .turnEnded = $0 { return true }; return false }),
              "result maps turnEnded")
        check(claudeEvents.contains(where: {
            if case .usageUpdate(let used, _, _, _, _, _) = $0 { return used != nil }
            return false
        }), "usage mapped")
        // Partial streaming (--include-partial-messages): deltas map to
        // chunks; the interleaved COMPLETE assistant frames repeat the
        // same content and must dedup against what deltas delivered.
        // Shape recorded from a live claude run (claude-stream.jsonl).
        let streamFixture = (CommandLine.arguments.count > 1
            ? CommandLine.arguments[1] : "tools/fixtures") + "/claude-stream.jsonl"
        let streamMapper = ClaudeFrameMapper()
        var streamTextChunks: [String] = []
        var streamThoughtChunks: [String] = []
        if let lines = try? String(contentsOfFile: streamFixture, encoding: .utf8) {
            for line in lines.split(separator: "\n") {
                guard let data = String(line).data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data),
                      let frame = json as? [String: Any] else { continue }
                for event in streamMapper.map(frame) {
                    switch event {
                    case .messageChunk(let text): streamTextChunks.append(text)
                    case .thoughtChunk(let text): streamThoughtChunks.append(text)
                    case .toolCallUpdate: break
                    default: break
                    }
                }
            }
        }
        check(streamTextChunks == ["1\n", "2\n", "3"],
              "text deltas stream as separate chunks, complete frame does not duplicate (got \(streamTextChunks))")
        check(streamThoughtChunks == ["The user wants a count."],
              "thinking delta streams once, interleaved frame deduped (got \(streamThoughtChunks))")
        check(streamTextChunks.joined() == "1\n2\n3", "streamed text reassembles")
        // History replay: the store file carries the asking side.
        let claudeHistory = ClaudeSessionStore.history(sessionId: "2123c193-59d5-4165-a29c-80372472a3f0")
        check(!claudeHistory.isEmpty, "claude store finds the probe session")
        var replayMapper = ClaudeFrameMapper()
        var replayEvents: [AgentSessionEvent] = []
        for frame in claudeHistory { replayEvents += replayMapper.map(frame) }
        check(replayEvents.contains(where: {
            if case .userChunk(let text) = $0 {
                return text.contains("HELLO_CLAUDE")
            }
            return false
        }), "history replay carries the user prompt")
        check(replayEvents.contains(where: {
            if case .messageChunk(let text) = $0 { return !text.isEmpty }
            return false
        }), "history replay carries assistant text")
        check(ClaudeFrameMapper.toolKind("Bash") == "execute"
              && ClaudeFrameMapper.toolKind("Edit") == "edit", "tool kinds mapped")

        print("— codex adapter —")
        check(AgentRegistry.descriptor(for: "codex")?.binary == "codex", "codex descriptor present")
        let codexFixture = (CommandLine.arguments.count > 1
            ? CommandLine.arguments[1] : "tools/fixtures") + "/codex-turn.jsonl"
        let codexMapper = CodexFrameMapper()
        var codexEvents: [AgentSessionEvent] = []
        if let raw = try? String(contentsOfFile: codexFixture, encoding: .utf8) {
            for line in raw.split(separator: "\n") {
                guard line.hasPrefix("CX> ") else { continue }
                guard let data = String(line.dropFirst(4)).data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data),
                      let frame = json as? [String: Any] else { continue }
                if let method = frame["method"] as? String {
                    codexEvents += codexMapper.map(method: method,
                                                   params: frame["params"] as? [String: Any] ?? [:])
                }
            }
        }
        check(codexEvents.contains(where: {
            if case .userChunk(let text) = $0 {
                return text.contains("HELLO_CODEX")
            }
            return false
        }), "userMessage item maps userChunk (started, no completed dup)")
        check(codexEvents.contains(where: {
            if case .messageChunk(let text) = $0 { return text.contains("[codex]") }
            return false
        }), "failed turn error surfaces as message")
        check(codexEvents.contains(where: {
            if case .turnEnded(let stop) = $0 { return stop == "failed" }
            return false
        }), "turn/completed maps turnEnded failed")
        check(codexMapper.notificationsIgnored >= 5, "reconnect chatter ignored (\(codexMapper.notificationsIgnored))")
        check(CodexFrameMapper.textOf([["type": "text", "text": "a"], ["type": "text", "text": "b"]]) == "ab",
              "codex content text join")

        print("— pi adapter —")
        check(AgentRegistry.descriptor(for: "pi")?.binary == "pi", "pi descriptor present")
        check(AgentRegistry.descriptors.map(\.key) == ["omp", "claude", "codex", "pi"],
              "registry order omp, claude, codex, pi")
        let piFixture = (CommandLine.arguments.count > 1
            ? CommandLine.arguments[1] : "tools/fixtures") + "/pi-rpc.jsonl"
        let piMapper = PiFrameMapper()
        var piEvents: [AgentSessionEvent] = []
        if let raw = try? String(contentsOfFile: piFixture, encoding: .utf8) {
            for line in raw.split(separator: "\n") {
                guard line.hasPrefix("PI> ") else { continue }
                guard let data = String(line.dropFirst(4)).data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data),
                      let frame = json as? [String: Any] else { continue }
                piEvents += piMapper.map(frame)
            }
        }
        // Deltas must assemble to exactly the message_end text.
        let assembled = piEvents.reduce(into: "") { acc, event in
            if case .messageChunk(let text) = event { acc += text }
        }
        check(assembled == "HELLO_PI", "pi deltas assemble (\(assembled))")
        check(piEvents.contains(where: {
            if case .userChunk = $0 { return true }; return false
        }) == false, "live user echo suppressed")
        check(piEvents.contains(where: {
            if case .turnEnded = $0 { return true }; return false
        }), "agent_settled maps turnEnded")
        check(piMapper.framesIgnored >= 9, "extension ui requests counted (\(piMapper.framesIgnored))")
        // Replay: get_messages payload from pi-resume.jsonl.
        let piResumeFixture = (CommandLine.arguments.count > 1
            ? CommandLine.arguments[1] : "tools/fixtures") + "/pi-resume.jsonl"
        let piReplayMapper = PiFrameMapper()
        var piReplayed: [AgentSessionEvent] = []
        if let raw = try? String(contentsOfFile: piResumeFixture, encoding: .utf8) {
            for line in raw.split(separator: "\n") {
                guard line.hasPrefix("PI> ") else { continue }
                guard let data = String(line.dropFirst(4)).data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data),
                      let frame = json as? [String: Any],
                      frame["id"] as? String == "m1",
                      let payload = frame["data"] as? [String: Any],
                      let messages = payload["messages"] as? [[String: Any]] else { continue }
                for message in messages {
                    piReplayed += piReplayMapper.mapReplayedMessage(message)
                }
            }
        }
        check(piReplayed.contains(where: {
            if case .userChunk(let text) = $0 { return text.contains("HELLO_PI") }
            return false
        }), "pi replay carries user prompt")
        check(piReplayed.contains(where: {
            if case .messageChunk(let text) = $0 { return text == "HELLO_PI" }
            return false
        }), "pi replay carries assembled assistant text")

        // pi store: real session files on this machine (probe cwd).
        let piSummaries = PiSessionStore.summaries(cwd: "/private/tmp/probe-cwd")
        check(piSummaries.contains { $0.title?.contains("HELLO_PI") == true },
              "pi session title derives from first user message")

        try? FileManager.default.removeItem(atPath: samplePath)
        if failures > 0 { exit(1) }
        print("agenttest: all passed")
    }
}

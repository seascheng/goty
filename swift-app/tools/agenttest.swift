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
        let rateLimitAssistant: [String: Any] = [
            "role": "assistant",
            "content": [],
            "stopReason": "error",
            "errorMessage": #"429 {"type":"error","error":{"message":"[1308][Usage limit reached for 5 hour. Your limit will reset at 19:37:34]"}}"#
        ]


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
        if case .userMessage(let userText)? = events.last, userText == "我看当前已经有了" {} else {
            failures += 1; print("FAIL  user echo in replay mode")
        }

        // agent_end: terminal for omp (turnEnded), non-terminal frames
        // (auto-retry boundaries) must not settle the turn.
        events += rpcMapper.map(["type": "agent_end", "isTerminal": false])
        if case .turnEnded?? = events.last { failures += 1; print("FAIL  non-terminal agent_end settled the turn") }
        events += rpcMapper.map(["type": "agent_end"])
        if case .turnEnded?? = events.last {} else { failures += 1; print("FAIL  terminal agent_end ends turn") }
        let rateLimitEvents = rpcMapper.map([
            "type": "agent_end", "messages": [rateLimitAssistant]
        ])
        check(rateLimitEvents.contains(where: {
            if case .turnEnded(let stop) = $0 { return stop == "error" }
            return false
        }), "provider error retains terminal stop reason")
        check(rateLimitEvents.contains(where: {
            if case .error(let text) = $0 {
                return text == "Usage limit reached for 5 hour. Your limit will reset at 19:37:34"
            }
            return false
        }), "live provider error surfaces its human message")
        let errorJS = AgentSessionEvent.error(text: "quota exhausted").jsRepresentation
        check(errorJS["type"] as? String == "error"
              && errorJS["text"] as? String == "quota exhausted",
              "provider error maps to web error event")
        // omp auto-retry: 429 → auto_retry_start (turn continues),
        // backoff exceeds retry.maxDelayMs → auto_retry_end
        // success:false carries the full retry story; the terminal
        // agent_end must not overwrite it with the bare provider text.
        let retryStart = rpcMapper.map(["type": "auto_retry_start",
                                        "attempt": 1, "maxAttempts": 3,
                                        "delayMs": 15_000,
                                        "errorMessage": #"429 {"type":"error","error":{"message":"[1308][Usage limit reached for 5 hour. Your limit will reset at 19:37:34]"}}"#,
                                        "errorId": 659456])
        if let scheduleEvent = retryStart.first,
           case .retryScheduled(let attempt, let maxAttempts, let delayMs, let errorText) = scheduleEvent,
           attempt == 1, maxAttempts == 3, delayMs == 15_000,
           errorText == "Usage limit reached for 5 hour. Your limit will reset at 19:37:34" {
        } else {
            failures += 1; print("FAIL  auto_retry_start schedules the countdown")
        }
        let retryEnd = rpcMapper.map(["type": "auto_retry_end", "success": false,
                                      "attempt": 1,
                                      "finalError": #"Provider requested 1800000ms wait, exceeds retry.maxDelayMs (300000ms). Original error: 429 {"type":"error","error":{"message":"[1308][Usage limit reached for 5 hour. Your limit will reset at 19:37:34]"}}"#])
        check(retryEnd.contains(where: {
            if case .error(let text) = $0 {
                return text.contains("Provider requested 1800000ms wait")
                    && text.contains("Original error: Usage limit reached for 5 hour. Your limit will reset at 19:37:34")
                    && !text.contains(#"{"type":"error""#)
            }
            return false
        }), "failed auto-retry surfaces the readable limit story")
        let retryTerminal = rpcMapper.map([
            "type": "agent_end", "messages": [rateLimitAssistant]
        ])
        let retryErrors = retryTerminal.filter {
            if case .error = $0 { return true }
            return false
        }
        check(retryErrors.count == 0, "terminal agent_end keeps the retry story, not the bare 429")
        check(retryTerminal.contains(where: {
            if case .turnEnded = $0 { return true }
            return false
        }), "retry-failed turn still settles")
        let retrySucceeded = rpcMapper.map(["type": "auto_retry_end",
                                            "success": true, "attempt": 2])
        check(retrySucceeded.isEmpty, "successful retry emits nothing")


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
        // Synthetic string user frames: command echoes compact to
        // "/name args", task receipts and local-command wrappers drop.
        let commandEcho = ClaudeFrameMapper.shapedUserEcho(
            "<command-name>/rename</command-name>\n"
            + "<command-message>rename</command-message>\n"
            + "<command-args>对接 claudecode</command-args>")
        check(commandEcho.compactMap {
            if case .userMessage(let text) = $0 { return text } else { return nil }
        } == ["/rename 对接 claudecode"], "claude command echo compacts to /name args")
        check(ClaudeFrameMapper.shapedUserEcho(
            "<task-notification>\n<task-id>t</task-id>\n</task-notification>").isEmpty,
            "claude task receipt drops")
        check(ClaudeFrameMapper.shapedUserEcho("真人输入").count == 1,
            "claude real typing passes through")
        // History persists one message as growing same-id frames —
        // dedup is per id, never across messages (flat counters lost
        // 78% of text / 92% of thinking on real sessions).
        let growthMapper = ClaudeFrameMapper()
        func growFrame(_ id: String, _ text: String) -> [String: Any] {
            ["type": "assistant",
             "message": ["id": id, "role": "assistant",
                         "content": [["type": "text", "text": text]]]]
        }
        var grownText: [String] = []
        for frame in [growFrame("m1", "第一段"), growFrame("m1", "第一段第二段"),
                      growFrame("m2", "第二消息")] {
            for event in growthMapper.map(frame) {
                if case .messageChunk(let text) = event { grownText.append(text) }
            }
        }
        check(grownText == ["第一段", "第二段", "第二消息"],
              "replay dedup is per message id (got \(grownText))")
        // TodoWrite tool_use feeds the plan dock (omp todoPhases parity).
        let todoFrame = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"TodoWrite","input":{"todos":[{"content":"调研","status":"completed"},{"content":"实现","status":"in_progress"}]}}]}}"#
        if let data = todoFrame.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data),
           let frame = json as? [String: Any] {
            let planEvents = claudeMapper.map(frame)
            check(planEvents.contains {
                if case .plan(let entries) = $0 { return entries.count == 2
                    && entries[1].status == "in_progress" }
                return false
            }, "claude TodoWrite maps to plan dock")
        }
        // History replay: the store file carries the asking side.
        let claudeHistory = ClaudeSessionStore.history(sessionId: "2123c193-59d5-4165-a29c-80372472a3f0")
        check(!claudeHistory.isEmpty, "claude store finds the probe session")
        var replayMapper = ClaudeFrameMapper()
        var replayEvents: [AgentSessionEvent] = []
        for frame in claudeHistory { replayEvents += replayMapper.map(frame) }
        check(replayEvents.contains(where: {
            if case .userMessage(let text) = $0 {
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
            if case .userMessage(let text) = $0 {
                return text.contains("HELLO_CODEX")
            }
            return false
        }), "userMessage item maps userMessage (started, no completed dup)")
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
        print("— missed-settle heal (/compact stuck-working regression) —")
        // /compact finishes without agent_settled: two consecutive idle
        // get_state reads must be allowed to force the turn closed…
        check(PiSession.missedSettleHeal(isWorking: true, streaming: false,
                                         queued: 0, compacting: false,
                                         activeToolCount: 0,
                                         secondsSinceSend: 30) == true,
              "post-compact idle read forces heal")
        // …but every sign of life vetoes it.
        check(PiSession.missedSettleHeal(isWorking: true, streaming: true,
                                         queued: 0, compacting: false,
                                         activeToolCount: 0,
                                         secondsSinceSend: 30) == false,
              "streaming vetoes heal")
        check(PiSession.missedSettleHeal(isWorking: true, streaming: false,
                                         queued: 1, compacting: false,
                                         activeToolCount: 0,
                                         secondsSinceSend: 30) == false,
              "queued follow-up vetoes heal")
        check(PiSession.missedSettleHeal(isWorking: true, streaming: false,
                                         queued: 0, compacting: true,
                                         activeToolCount: 0,
                                         secondsSinceSend: 30) == false,
              "compaction in flight vetoes heal")
        check(PiSession.missedSettleHeal(isWorking: true, streaming: false,
                                         queued: 0, compacting: false,
                                         activeToolCount: 2,
                                         secondsSinceSend: 30) == false,
              "open tool call vetoes heal")
        check(PiSession.missedSettleHeal(isWorking: true, streaming: false,
                                         queued: 0, compacting: false,
                                         activeToolCount: 0,
                                         secondsSinceSend: 2) == false,
              "optimistic send window (<4s) vetoes heal")
        check(PiSession.missedSettleHeal(isWorking: false, streaming: false,
                                         queued: 0, compacting: false,
                                         activeToolCount: 0,
                                         secondsSinceSend: 30) == false,
              "already-idle session needs no heal")

        // Compacting debounce + strong-veto streak (the poisoned-turn
        // regression: mid-turn set_model kills the turn, omp flaps
        // isCompacting true/false on alternating reads, the status
        // line flickered 思考中/压缩中 and the heal never landed).
        check(PiSession.effectiveCompacting(current: true, previous: true) == true,
              "steady compaction counts (two consecutive true reads)")
        check(PiSession.effectiveCompacting(current: true, previous: false) == false
              && PiSession.effectiveCompacting(current: false, previous: true) == false
              && PiSession.effectiveCompacting(current: false, previous: false) == false,
              "lone or flapping compacting reads are noise")
        check(PiSession.strongLifeSign(streaming: true, queued: 0, activeToolCount: 0)
              && PiSession.strongLifeSign(streaming: false, queued: 1, activeToolCount: 0)
              && PiSession.strongLifeSign(streaming: false, queued: 0, activeToolCount: 2),
              "streaming/queued/open tools are strong life signs")
        check(PiSession.strongLifeSign(streaming: false, queued: 0, activeToolCount: 0) == false,
              "an idle read (or lone compacting blip) must not reset the heal streak")
        // A real compaction still vetoes the heal through the debounced
        // flag (steady true) — the streak fix must not break /compact.
        check(PiSession.missedSettleHeal(isWorking: true, streaming: false,
                                         queued: 0,
                                         compacting: PiSession.effectiveCompacting(current: true, previous: true),
                                         activeToolCount: 0,
                                         secondsSinceSend: 30) == false,
              "steady compaction still vetoes heal after debounce")

        print("— omp store provider errors —")
        let rateLimitRecord: [String: Any] = [
            "type": "message", "id": "error-entry", "message": rateLimitAssistant
        ]
        let rateLimitRaw = String(data: try! JSONSerialization.data(withJSONObject: rateLimitRecord),
                                  encoding: .utf8)!
        let storedRateLimit = OmpSessionStore.parse(rateLimitRaw)
        check(storedRateLimit.events.contains(where: {
            if case .error(let text) = $0 {
                return text.contains("Usage limit reached for 5 hour")
            }
            return false
        }), "stored provider error survives transcript parse")
        let historicalRateLimit = OmpSessionStore.parse(rateLimitRaw, includeTerminalError: false)
        check(!historicalRateLimit.events.contains(where: {
            if case .error = $0 { return true }
            return false
        }), "older transcript page cannot replace the current error")


        print("— omp store open-tail detection —")
        // A toolCall started but never completed (read raced the settle)
        // must report openTools > 0; the completing toolResult closes it.
        do {
            let dir = NSTemporaryDirectory() + "goty-openTail-\(UUID().uuidString)"
            // The store nests one cwd-bucket directory deep; fileURL
            // only searches subdirectories of root.
            let bucket = dir + "/goty-test-cwd"
            try FileManager.default.createDirectory(atPath: bucket, withIntermediateDirectories: true)
            let sid = UUID().uuidString
            let path = bucket + "/2026-09-01T00-00-00-000Z_\(sid).jsonl"
            let start = #"{"type":"custom","customType":"tool_execution_start","id":"e1","data":{"toolCallId":"call_x","intent":"bash"}}"#
            try "{\"type\":\"session\",\"id\":\"\(sid)\"}\n\(start)\n"
                .write(toFile: path, atomically: true, encoding: .utf8)
            OmpSessionStore.rootOverride = URL(fileURLWithPath: dir)
            let loaded1 = OmpSessionStore.load(sessionId: sid)
            check(loaded1.openTools == 1, "unsettled tool tail reports openTools=1")
            let result = #"{"type":"message","id":"e2","message":{"role":"toolResult","toolCallId":"call_x","toolName":"bash","content":[]}}"#
            try "\(start)\n\(result)\n"
                .write(toFile: path, atomically: true, encoding: .utf8)
            let loaded2 = OmpSessionStore.load(sessionId: sid)
            check(loaded2.openTools == 0, "toolResult closes the open tail")
            OmpSessionStore.rootOverride = nil
            try? FileManager.default.removeItem(atPath: dir)
        } catch {
            check(false, "open-tail fixture threw: \(error)")
            OmpSessionStore.rootOverride = nil
        }

        print("— /rename + history title fallback —")
        // omp's session_info_update frame (/rename, auto-naming) is the
        // live title event; it must reach the page as sessionTitle.
        let renameMapper = PiFrameMapper(terminalOnAgentEnd: true)
        let renameEvents = renameMapper.map([
            "type": "session_info_update", "title": "bug fix",
            "sessionId": "s1"])
        check(renameEvents.contains {
            if case .sessionTitle(let t) = $0 { return t == "bug fix" }
            return false
        }, "/rename frame maps to live sessionTitle")
        check(renameMapper.map(["type": "session_info_update", "title": ""])
            .isEmpty, "empty retitle emits nothing")
        // Untitled sessions (probes, aborted turns) fall back to the
        // first user message — not 未命名会话 soup.
        do {
            let dir = NSTemporaryDirectory() + "goty-title-\(UUID().uuidString)"
            let bucket = dir + "/goty-test-cwd"
            try FileManager.default.createDirectory(atPath: bucket, withIntermediateDirectories: true)
            let sid = UUID().uuidString
            let path = bucket + "/2026-09-01T00-00-00-000Z_\(sid).jsonl"
            let sessionLine = #"{"type":"session","cwd":"/x"}"#
            let userLine = #"{"type":"message","id":"m1","message":{"role":"user","content":[{"type":"text","text":"修复弹框错位"}]}}"#
            let untitledContent = [
                sessionLine,
                #"{"type":"title","v":1,"title":"","pad":""}"#,
                userLine,
            ].joined(separator: "\n") + "\n"
            try untitledContent.write(toFile: path, atomically: true, encoding: .utf8)
            OmpSessionStore.rootOverride = URL(fileURLWithPath: dir)
            let untitled = OmpSessionStore.summaries(cwd: nil)
            check(untitled.first?.title == "修复弹框错位",
                  "untitled session derives history title from first user message")
            // A real rename outranks the derived fallback.
            let renamedContent = [
                sessionLine,
                #"{"type":"title","v":1,"title":"bug fix","pad":""}"#,
                userLine,
            ].joined(separator: "\n") + "\n"
            try renamedContent.write(toFile: path, atomically: true, encoding: .utf8)
            let renamed = OmpSessionStore.summaries(cwd: nil)
            check(renamed.first?.title == "bug fix",
                  "explicit /rename title outranks the derived fallback")
            check((Int(renamed.first?.updatedAt ?? "") ?? 0) > 0,
                  "summaries carry updatedAt (epoch seconds) for the web fallback")
            OmpSessionStore.rootOverride = nil
            try? FileManager.default.removeItem(atPath: dir)
        } catch {
            check(false, "title fixture threw: \(error)")
            OmpSessionStore.rootOverride = nil
        }

        // Mid-turn builtin deferral (pi-mono, omp AND pi): only the
        // session's own command directory entries are parked; unknown
        // /text and plain text steer as typed.
        check(PiSession.isBuiltinCommand("/rename", commandNames: ["rename", "compact"])
              && PiSession.isBuiltinCommand("/rename my name", commandNames: ["rename"]),
              "known builtin with or without args is deferred")
        check(PiSession.isBuiltinCommand("/unknown", commandNames: ["rename"]) == false
              && PiSession.isBuiltinCommand("plain steering", commandNames: ["rename"]) == false
              && PiSession.isBuiltinCommand("/x", commandNames: []) == false,
              "unknown or empty-directory /text steers instead of deferring")

        // Image attachments: the composer's {mimeType, data: base64}
        // becomes the pi-mono RPC ImageContent verbatim; malformed
        // entries drop rather than poison the frame.
        let img = AgentImage(["mimeType": "image/png", "data": "aGk="])
        check(img?.piWire["type"] as? String == "image"
              && img?.piWire["mimeType"] as? String == "image/png"
              && img?.piWire["data"] as? String == "aGk=",
              "AgentImage carries the pi-mono ImageContent shape")
        check(AgentImage(["mimeType": "image/png"]) == nil
              && AgentImage(["data": "aGk="]) == nil
              && AgentImage(["type": "image", "mimeType": "image/png",
                             "data": "aGk="]) != nil,
              "AgentImage rejects missing fields, ignores extras")

        print("— pi adapter —")
        check(AgentRegistry.descriptor(for: "pi")?.binary == "pi", "pi descriptor present")
        // get_commands only lists EXTENSION commands (probed 0.84.3:
        // 79 entries, no compact) — the builtin supplement must carry
        // pi's own registry, deduped against whatever the RPC reports.
        check(PiLegacySession.builtinCommands.count == 23
              && PiLegacySession.builtinCommands.contains { $0.name == "compact" },
              "pi builtin directory carries /compact (get_commands omits builtins)")
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
        let piRateLimitEvents = piMapper.map([
            "type": "message_end", "message": rateLimitAssistant
        ])
        check(piRateLimitEvents.contains(where: {
            if case .error(let text) = $0 {
                return text.contains("Usage limit reached for 5 hour")
            }
            return false
        }), "pi assistant error surfaces before agent_settled")
        check(piMapper.map(["type": "agent_settled"]).contains(where: {
            if case .turnEnded = $0 { return true }
            return false
        }), "pi rate-limit turn still settles")

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
            if case .userMessage(let text) = $0 { return text.contains("HELLO_PI") }
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

        // Capability alignment: the Swift client's capability constants
        // must trail the Rust daemon's CAPABILITY — the three live in
        // two languages and drift silently otherwise (a client asking
        // above the daemon's level degrades instead of erroring).
        var rustSource = #filePath
        if !rustSource.hasPrefix("/") {
            rustSource = FileManager.default.currentDirectoryPath + "/" + rustSource
        }
        let protoPath = URL(fileURLWithPath: rustSource)  // tools/agenttest.swift
            .deletingLastPathComponent()                   // tools/
            .deletingLastPathComponent()                   // swift-app/
            .appendingPathComponent("sessiond/src/protocol.rs").path
        if let proto = try? String(contentsOfFile: protoPath, encoding: .utf8),
           let line = proto.split(separator: "\n")
               .first(where: { $0.contains("pub const CAPABILITY") }),
           let rustCap = Int(String(line.split(separator: "=", maxSplits: 1).last ?? "")
               .trimmingCharacters(in: .whitespacesAndNewlines)
               .trimmingCharacters(in: CharacterSet(charactersIn: "; "))) {
            check(SessionDaemon.storeCapability <= rustCap,
                  "Swift storeCapability (\(SessionDaemon.storeCapability)) <= Rust CAPABILITY (\(rustCap))")
            check(SessionDaemon.expectedCapability <= SessionDaemon.storeCapability,
                  "Swift expectedCapability (\(SessionDaemon.expectedCapability)) <= storeCapability")
        } else {
            check(false, "sessiond protocol.rs CAPABILITY parseable")
        }

        try? FileManager.default.removeItem(atPath: samplePath)
        if failures > 0 { exit(1) }
        print("agenttest: all passed")
    }
}

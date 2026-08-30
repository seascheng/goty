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
        check((plain["size"] as? [String: UInt16])?["cols"] == 120, "grid passes through")

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

        print("— AgentSession.interpret —")
        var events: [AgentSessionEvent] = []
        let daemon = SessionDaemon(socketPath: "/nonexistent-\(UUID().uuidString)")
        let session = OmpSession(paneId: "p1", cwd: nil, grid: grid,
                                   environment: [:],
                                   spawn: AgentSpawn(
                                       command: "omp", args: ["acp"],
                                       ringBytes: 67_108_864),
                                   daemon: daemon, delegate: nil)
        events += session.interpret(["method": "session/update", "params": [
            "sessionId": "s1",
            "update": ["sessionUpdate": "agent_message_chunk",
                       "content": ["type": "text", "text": "hello"]],
        ]])
        events += session.interpret(["method": "session/update", "params": [
            "sessionId": "s1",
            "update": ["sessionUpdate": "tool_call", "toolCallId": "t1",
                       "title": "Read file", "kind": "read", "status": "completed",
                       "content": [["type": "text", "text": "src/main.rs"]]],
        ]])
        check(events.count == 2, "two events so far")
        if case .messageChunk(let text)? = events.first, text == "hello" {} else { failures += 1; print("FAIL  messageChunk payload") }
        if case .toolCallUpdate(let id, _, _, let status, let content, let output, let rawInput, let oldText) = events.last,
           id == "t1", status == "completed", content.count == 1, output.isEmpty,
           rawInput == nil, oldText == nil {} else { failures += 1; print("FAIL  toolCallUpdate payload") }

        events += session.interpret(["method": "session/update", "params": [
            "sessionId": "s1",
            "update": ["sessionUpdate": "tool_call", "toolCallId": "t2", "kind": "edit",
                       "status": "pending",
                       "rawInput": ["path": samplePath, "content": "new"],
                       "content": [["type": "text", "text": "x"]]],
        ]])
        if case .toolCallUpdate(_, _, let kind, _, _, _, let editInput, let oldText)? = events.last,
           kind == "edit",
           let editPath = editInput?["path"] as? String, editPath == samplePath,
           oldText == "old content" {} else { failures += 1; print("FAIL  edit oldText snapshot") }

        // Replayed history echoes the user's prompts as user_message_chunk;
        // dropping them erased every user turn from resumed transcripts.
        events += session.interpret(["method": "session/update", "params": [
            "sessionId": "s1",
            "update": ["sessionUpdate": "user_message_chunk",
                       "content": ["type": "text", "text": "我看当前已经有了"]],
        ]])
        if case .userChunk(let userText)? = events.last, userText == "我看当前已经有了" {} else {
            failures += 1; print("FAIL  user_message_chunk replay")
        }
        // Full fidelity, both wire shapes: nested content wrappers and
        // rawOutput results survive untouched — no cap. The old flat-only
        // reader plus the 64 KiB cap dropped exactly these on resume.
        events += session.interpret(["method": "session/update", "params": [
            "sessionId": "s1",
            "update": ["sessionUpdate": "tool_call_update", "toolCallId": "t3",
                       "status": "completed",
                       "content": [["type": "content", "content":
                                       ["type": "text", "text": String(repeating: "x", count: 100_000)]]],
                       "rawOutput": ["content": [["type": "text", "text": "tool result body"]]],
        ]]])
        if case .toolCallUpdate(_, _, _, _, let big, let bigOut, _, _)? = events.last,
           big.first?.text?.count == 100_000,
           bigOut.first?.text == "tool result body" {} else {
            failures += 1; print("FAIL  full-fidelity tool payloads (nested + rawOutput, no cap)")
        }

        events += session.interpret(["method": "session/update", "params": [
            "sessionId": "s1",
            "update": ["sessionUpdate": "plan",
                       "entries": [["content": "step 1", "priority": "high", "status": "pending"]]],
        ]])
        if case .plan(let entries)? = events.last, entries.count == 1,
           entries[0].content == "step 1" {} else { failures += 1; print("FAIL  plan payload") }

        events += session.interpret(["id": 7, "method": "session/request_permission", "params": [
            "sessionId": "s1", "toolCall": ["title": "bash"],
            "options": [["optionId": "allow", "name": "Allow", "kind": "allow_once"]],
        ]])
        if case .permissionRequested(let prompt)? = events.last, prompt.requestID == "7",
           prompt.toolCallTitle == "bash",
           prompt.options.first?.optionId == "allow" {} else { failures += 1; print("FAIL  permission prompt") }

        events += session.interpret(["method": "session/update", "params": [
            "sessionId": "s1",
            "update": ["sessionUpdate": "available_commands_update",
                       "availableCommands": [["name": "model", "description": "Show current model"],
                                             ["name": "fast", "input": ["hint": "[on|off]"]]]],
        ]])
        if case .commandsChanged(let commands)? = events.last, commands.count == 2,
           commands[0].name == "model", commands[1].inputHint == "[on|off]" {} else { failures += 1; print("FAIL  commands payload") }
        check(session.commands.count == 2, "commands stored on session")

        events += session.interpret(["method": "session/update", "params": [
            "sessionId": "s1",
            "update": ["sessionUpdate": "usage_update", "used": 19754, "size": 1000000,
                       "input": 18000, "output": 1754,
                       "cost": ["amount": 0.0171, "currency": "USD"]],
        ]])
        if case .usageUpdate(let used, let size, let input, let output,
                              let costAmount, let costCurrency)? = events.last,
           used == 19754, size == 1000000, input == 18000, output == 1754,
           costAmount == 0.0171, costCurrency == "USD" {} else { failures += 1; print("FAIL  usage payload") }
        events += session.interpret(["method": "session/update", "params": [
            "sessionId": "s1",
            "update": ["sessionUpdate": "usage_update", "used": 19754, "size": 1000000,
                       "cost": ["amount": 0.0171, "currency": "USD"]],
        ]])
        if case .usageUpdate(_, _, let noIn, let noOut, _, _)? = events.last,
           noIn == nil && noOut == nil {} else { failures += 1; print("FAIL  usage without token split stays nil") }

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

        print("— integrity counters —")
        check(session.bytesFed == 0 && session.eventsEmitted > 0,
              "events counted without frames fed")
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
        check(omp?.spawn.command == "omp" && omp?.spawn.args == ["acp"], "omp acp spawn")
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

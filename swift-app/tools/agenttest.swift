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

        print("— JSONRPCChannel echo filter + routing —")
        let client = JSONRPCChannel()
        var notifications: [(String, [String: Any])] = []
        client.onNotification = { notifications.append(($0, $1)) }
        var outbound: [[UInt8]] = []
        client.onOutbound = { outbound.append($0) }
        var got: Result<[String: Any], RPCFailure>?
        client.request("initialize", ["protocolVersion": 1]) { got = $0 }
        let sentLine = String(decoding: outbound[0], as: UTF8.self)
        // stty 竞态窗口的回显：逐字节原样回来，必须被丢弃且不影响 pending
        client.feed(Array(sentLine.utf8))
        check(notifications.isEmpty, "echoed request dropped")
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
        let session = AgentSession(paneId: "p1", cwd: nil, grid: grid,
                                   environment: [:],
                                   launch: AgentManifests.ACPLaunch(
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
        if case .permissionRequested(let prompt)? = events.last, prompt.requestID == 7,
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

        print("— manifest —")
        let launch = AgentManifests.acpLaunch(for: "omp")
        check(launch?.command == "omp" && launch?.args == ["acp"], "omp acp launch")
        check(launch?.ringBytes == 67_108_864, "omp uses the 64 MiB ring")
        check(AgentManifests.acpLaunch(for: "claude") == nil, "v1 is omp-only")
        check(AgentManifests.acpPickerOrder.first?.key == "omp", "picker order leads with omp")

        try? FileManager.default.removeItem(atPath: samplePath)
        if failures > 0 { exit(1) }
        print("agenttest: all passed")
    }
}

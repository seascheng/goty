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
        // A server request replayed from the ring carries the DEAD
        // process's id space — routing it to onRequest creates phantom
        // permission cards (5090: approval never seen, tools spinning).
        var phantomServerRequests = 0
        rcPrompt.onRequest = { _, _, _ in phantomServerRequests += 1 }
        rcPrompt.feed(Array("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"item/commandExecution/requestApproval\",\"params\":{\"kind\":\"command\",\"itemId\":\"exec-x\"}}\n".utf8), replay: true)
        check(phantomServerRequests == 0 && promptReplays.count == 2,
              "replayed server request stays out of onRequest")
        // LIVE approval traffic still reaches onRequest.
        rcPrompt.feed(Array("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"item/commandExecution/requestApproval\",\"params\":{\"kind\":\"command\",\"itemId\":\"exec-y\"}}\n".utf8))
        check(phantomServerRequests == 1, "live server request reaches onRequest")

        print("— JSONRPCChannel callback queue + lifecycle —")
        func wait(_ semaphore: DispatchSemaphore, seconds: Double = 1) -> Bool {
            semaphore.wait(timeout: .now() + seconds) == .success
        }
        let deliveryQueue = DispatchQueue(label: "goty.agenttest.rpc-callback")
        let deliveryKey = DispatchSpecificKey<String>()
        deliveryQueue.setSpecific(key: deliveryKey, value: "rpc")
        let delivered = DispatchSemaphore(value: 0)
        let queued = JSONRPCChannel(callbackQueue: deliveryQueue)
        var callbackOrder: [String] = []
        var callbackQueueWasCorrect = true
        queued.onNotification = { method, _ in
            callbackQueueWasCorrect = callbackQueueWasCorrect
                && DispatchQueue.getSpecific(key: deliveryKey) == "rpc"
            callbackOrder.append(method)
            if callbackOrder.count == 2 { delivered.signal() }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            queued.feed(Array("{\"method\":\"first\"}\n{\"method\":\"second\"}\n".utf8))
        }
        check(wait(delivered), "JSON-RPC queued callbacks finish")
        check(callbackQueueWasCorrect, "JSON-RPC callbacks use configured queue")
        check(callbackOrder == ["first", "second"], "JSON-RPC callbacks keep wire order")

        let teardown = JSONRPCChannel()
        teardown.onOutbound = { _ in }
        var teardownFailures = 0
        teardown.request("one", [:]) { result in
            if case .failure = result { teardownFailures += 1 }
        }
        teardown.request("two", [:]) { result in
            if case .failure = result { teardownFailures += 1 }
        }
        check(teardown.debugPendingCount == 2, "JSON-RPC tracks pending requests")
        teardown.failPending(reason: "transport disconnected")
        teardown.failPending(reason: "duplicate teardown")
        check(teardownFailures == 2, "JSON-RPC teardown fails each request once")
        check(teardown.debugPendingCount == 0, "JSON-RPC teardown drains pending requests")

        // Lock separation: a slow parser on the reader thread must not
        // block request registration from another thread (the old single
        // lock serialized both).
        let parserEntered = DispatchSemaphore(value: 0)
        let parserRelease = DispatchSemaphore(value: 0)
        let requestReturned = DispatchSemaphore(value: 0)
        let contention = JSONRPCChannel(parser: { data in
            parserEntered.signal()
            _ = parserRelease.wait(timeout: .now() + 2)
            return try? JSONSerialization.jsonObject(with: data)
        })
        contention.onOutbound = { _ in }
        DispatchQueue.global(qos: .userInitiated).async {
            contention.feed(Array("{\"method\":\"blocked-parser\"}\n".utf8))
        }
        check(wait(parserEntered), "JSON-RPC parser seam entered")
        DispatchQueue.global(qos: .userInitiated).async {
            contention.request("must-not-wait-for-parser", [:]) { _ in }
            requestReturned.signal()
        }
        check(wait(requestReturned, seconds: 0.25),
              "request registration does not wait for JSON parsing")
        parserRelease.signal()
        contention.failPending(reason: "test complete")

        print("— LineChannel callback queue + replay metadata —")
        let lineQueue = DispatchQueue(label: "goty.agenttest.line-callback")
        let lineKey = DispatchSpecificKey<String>()
        lineQueue.setSpecific(key: lineKey, value: "line")
        let lineDone = DispatchSemaphore(value: 0)
        let lineChannel = LineChannel(callbackQueue: lineQueue)
        var lineQueueWasCorrect = false
        var replayFlag = false
        lineChannel.onFrame = { _, replay in
            lineQueueWasCorrect = DispatchQueue.getSpecific(key: lineKey) == "line"
            replayFlag = replay
            lineDone.signal()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            lineChannel.feed(Array("{\"type\":\"message\"}\n".utf8), replay: true)
        }
        check(wait(lineDone), "line callback finishes")
        check(lineQueueWasCorrect, "line callback uses configured queue")
        check(replayFlag, "line callback preserves replay metadata")

        let replayBoundaryDone = DispatchSemaphore(value: 0)
        let replayBoundary = LineChannel(callbackQueue: lineQueue)
        var replaySequence: [Bool] = []
        replayBoundary.onFrame = { _, replay in
            replaySequence.append(replay)
            if replaySequence.count == 2 { replayBoundaryDone.signal() }
        }
        replayBoundary.feed(Array("{\"type\":\"snapshot\"}\n".utf8), replay: true)
        replayBoundary.feed(Array("{\"type\":\"live\"}\n".utf8), replay: false)
        check(wait(replayBoundaryDone), "line replay/live callbacks finish")
        check(replaySequence == [true, false], "line callbacks preserve replay/live order")

        print("— agent session execution boundary —")
        let workStarted = DispatchSemaphore(value: 0)
        let releaseWork = DispatchSemaphore(value: 0)
        var workWasOffMain = false
        var completionWasMain = false
        var executionDone = false
        AgentSessionExecution.runOffMain(work: {
            workWasOffMain = !Thread.isMainThread
            workStarted.signal()
            _ = releaseWork.wait(timeout: .now() + 2)
            return 42
        }, completion: { value in
            completionWasMain = Thread.isMainThread && value == 42
            executionDone = true
        })
        check(wait(workStarted), "connection work starts")
        var markerRan = false
        DispatchQueue.main.async { markerRan = true }
        let markerDeadline = Date().addingTimeInterval(0.5)
        while !markerRan, Date() < markerDeadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        check(markerRan, "blocked connection work does not block main queue")
        releaseWork.signal()
        let completionDeadline = Date().addingTimeInterval(1)
        while !executionDone, Date() < completionDeadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        check(workWasOffMain, "connection work runs off main")
        check(completionWasMain, "connection completion returns to main")

        let staleStarted = DispatchSemaphore(value: 0)
        let staleRelease = DispatchSemaphore(value: 0)
        let gate = AgentConnectionGate()
        var acceptedConnections: [String] = []
        var discardedConnections: [String] = []
        gate.open(work: {
            staleStarted.signal()
            _ = staleRelease.wait(timeout: .now() + 2)
            return "old"
        }, onStale: { discardedConnections.append($0) },
           completion: { acceptedConnections.append($0) })
        check(wait(staleStarted), "old connection attempt starts")
        gate.open(work: { "new" },
                  onStale: { discardedConnections.append($0) },
                  completion: { acceptedConnections.append($0) })
        let acceptedDeadline = Date().addingTimeInterval(1)
        while acceptedConnections.isEmpty, Date() < acceptedDeadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        staleRelease.signal()
        let discardedDeadline = Date().addingTimeInterval(1)
        while discardedConnections.isEmpty, Date() < discardedDeadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        check(acceptedConnections == ["new"], "only newest connection is accepted")
        check(discardedConnections == ["old"], "stale connection is discarded")

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
        check(omp?.spawn.command == "omp" && omp?.spawn.args == ["--mode", "rpc-ui"], "omp rpc spawn")
        check(omp?.spawn.ringBytes == 1_048_576,
              "pi-mono panes use the 1 MiB ring (live value: PiSession.openPane)")
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
        // 0.153 tags the assistant reply `agentMessage` (content
        // blocks); 0.147-era docs said assistantMessage. Both must
        // render as TEXT, deduped per item id.
        do {
            let m = CodexFrameMapper()
            let frame: [String: Any] = [
                "item": ["type": "agentMessage", "id": "i1",
                         "content": [["type": "text", "text": "HELLO_AGENT"]]]
            ]
            let legacy: [String: Any] = [
                "item": ["type": "assistantMessage", "id": "i2",
                         "content": [["type": "text", "text": "OLD_TAG"]]]
            ]
            var events: [AgentSessionEvent] = []
            events += m.map(method: "item/started", params: frame)
            events += m.map(method: "item/completed", params: frame)
            events += m.map(method: "item/completed", params: legacy)
            let texts = events.compactMap { event -> String? in
                if case .messageChunk(let t) = event { return t }
                return nil
            }
            check(texts == ["HELLO_AGENT", "OLD_TAG"],
                  "agentMessage/assistantMessage render as text, started+completed dedup to one")
        }
        // 0.153 streams agentMessage deltas; the completed item must
        // not repeat the whole text after them.
        do {
            let m = CodexFrameMapper()
            var chunks: [String] = []
            for delta in ["HEL", "LO_", "CODEX"] {
                chunks += m.map(method: "item/agentMessage/delta",
                                params: ["itemId": "m1", "delta": delta])
                    .compactMap { event -> String? in
                        if case .messageChunk(let t) = event { return t }
                        return nil
                    }
            }
            let completed = m.map(method: "item/completed", params: [
                "item": ["type": "agentMessage", "id": "m1",
                         "text": "HELLO_CODEX"]])
                .compactMap { event -> String? in
                    if case .messageChunk(let t) = event { return t }
                    return nil
                }
            check(chunks == ["HEL", "LO_", "CODEX"]
                  && completed.isEmpty,
                  "agentMessage deltas stream and the completed item does not repeat them")
        }
        // paseo: "emits only the missing assistant suffix when completed
        // text extends streamed deltas" — a completed text longer than
        // what streamed backfills the gap, never the whole text.
        do {
            let m = CodexFrameMapper()
            _ = m.map(method: "item/agentMessage/delta",
                      params: ["itemId": "m2", "delta": "Hel"])
            _ = m.map(method: "item/agentMessage/delta",
                      params: ["itemId": "m2", "delta": "lo"])
            let suffixEvents = m.map(method: "item/completed", params: [
                "item": ["type": "agentMessage", "id": "m2",
                         "text": "Hello world"]])
            let texts = suffixEvents.compactMap { event -> String? in
                if case .messageChunk(let t) = event { return t }
                return nil
            }
            check(texts == [" world"],
                  "completed assistant text backfills only the missing suffix")
            // Equal text backfills nothing.
            _ = m.map(method: "item/agentMessage/delta",
                      params: ["itemId": "m3", "delta": "same"])
            check(m.map(method: "item/completed", params: [
                "item": ["type": "agentMessage", "id": "m3",
                         "text": "same"]]).isEmpty,
                  "equal completed assistant text stays silent")
        }
        // paseo: "streams Codex reasoning deltas and does not replay
        // completed reasoning" + missing-suffix backfill.
        do {
            let m = CodexFrameMapper()
            var thoughts: [String] = []
            for d in ["思", "考中"] {
                thoughts += m.map(method: "item/reasoning/summaryTextDelta",
                                  params: ["itemId": "r2", "delta": d])
                    .compactMap { if case .thoughtChunk(let t) = $0 { return t } else { return nil } }
            }
            let backfill = m.map(method: "item/completed", params: [
                "item": ["type": "reasoning", "id": "r2",
                         "summary": ["思考中…完毕"], "content": []]])
                .compactMap { if case .thoughtChunk(let t) = $0 { return t } else { return nil } }
            check(thoughts == ["思", "考中"] && backfill == ["…完毕"],
                  "reasoning deltas stream and completed backfills only the gap")
        }
        // Approval decision literals (paseo round-trips these through
        // the real app-server transport; schema-verified).
        check(CodexSession.approvalDecision("allow_once") == "accept"
              && CodexSession.approvalDecision("allow_session") == "acceptForSession"
              && CodexSession.approvalDecision("reject_once") == "decline",
              "approval options map to schema decision literals")
        // turn/aborted (turn/interrupt) ends the turn without
        // turn/completed; token usage maps `last` (never cumulative
        // `total`) as the context-window measure.
        do {
            let m = CodexFrameMapper()
            var events: [AgentSessionEvent] = []
            events += m.map(method: "turn/aborted", params: [:])
            events += m.map(method: "thread/tokenUsage/updated", params: [
                "tokenUsage": [
                    "last": ["totalTokens": 12_000],
                    "total": ["totalTokens": 900_000],
                    "modelContextWindow": 200_000,
                ]])
            if case .turnEnded(let stop)? = events.first {
                check(stop == "interrupted", "turn/aborted maps turnEnded interrupted")
            } else {
                check(false, "turn/aborted maps turnEnded interrupted")
            }
            let usage = events.dropFirst().compactMap { event -> AgentSessionEvent? in
                if case .usageUpdate = event { return event }
                return nil
            }.first
            if case .usageUpdate(let used?, let size?, _, _, _, _)? = usage {
                check(used == 12_000 && size == 200_000,
                      "token usage maps last.totalTokens + window, not cumulative total")
            } else {
                check(false, "token usage maps last.totalTokens + window, not cumulative total")
            }
        }
        check(CodexFrameMapper.textOf([["type": "text", "text": "a"], ["type": "text", "text": "b"]]) == "ab",
              "codex content text join")
        // Protocol-audit branches (docs/codex-protocol-coverage.md):
        // reasoning deltas stream + the completed item stays silent;
        // commandExecution/outputDelta accumulates into the tool card;
        // turn/plan/updated maps steps to plan entries.
        do {
            let m = CodexFrameMapper()
            var thoughts: [String] = []
            for d in ["思考", "片段"] {
                thoughts += m.map(method: "item/reasoning/summaryTextDelta",
                                  params: ["itemId": "rs_1", "delta": d])
                    .compactMap { if case .thoughtChunk(let t) = $0 { return t } else { return nil } }
            }
            let completed = m.map(method: "item/completed",
                                  params: ["item": ["type": "reasoning", "id": "rs_1",
                                                    "summary": ["思考片段"], "content": []]])
            check(thoughts == ["思考", "片段"] && completed.isEmpty,
                  "reasoning deltas stream and the completed item does not repeat")
        }
        do {
            let m = CodexFrameMapper()
            var outputs: [String] = []
            for d in ["line1\n", "line2\n"] {
                outputs += m.map(method: "item/commandExecution/outputDelta",
                                 params: ["itemId": "exec_9", "delta": d])
                    .compactMap { ev -> String? in
                        if case .toolCallUpdate(_, _, _, _, _, let out, _, _) = ev {
                            return out.first?.text
                        }
                        return nil
                    }
            }
            check(outputs == ["line1\n", "line1\nline2\n"],
                  "outputDelta accumulates the full buffer per item")
        }
        do {
            let m = CodexFrameMapper()
            let events = m.map(method: "turn/plan/updated", params: [
                "threadId": "t", "turnId": "u", "explanation": NSNull(),
                "plan": [["step": "收集证据", "status": "completed"],
                         ["step": "写文档", "status": "pending"]] as [[String: Any]]])
            if case .plan(let entries)? = events.first {
                check(entries.map(\.content) == ["收集证据", "写文档"]
                      && entries.map(\.status) == ["completed", "pending"],
                      "plan steps map with statuses")
            } else {
                check(false, "turn/plan/updated emits a plan")
            }
        }
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

        print("— live settle-stamp: fresh entry marks —")
        // Live frames carry no entry ids; after a turn settles the
        // session re-reads the store and ships only NEW marks,
        // content-gated and newest-first. The error tail (a3) has no
        // text — its mark must not ship, or it would steal a2's block.
        do {
            let sid = UUID().uuidString
            func entry(_ id: String, _ role: String, _ text: String) -> String {
                let content = text.isEmpty ? "[]" : #"[{"type":"text","text":"\#(text)"}]"#
                return #"{"type":"message","id":"\#(id)","message":{"role":"\#(role)","content":\#(content)}}"#
            }
            let raw = [
                #"{"type":"session","id":"\#(sid)"}"#,
                entry("u1", "user", "hi"),
                entry("a1", "assistant", "hello"),
                entry("u2", "user", "again"),
                entry("a2", "assistant", "sure"),
                entry("a3", "assistant", ""),   // empty provider-error tail
            ].joined(separator: "\n")
            func roles(_ events: [AgentSessionEvent]) -> [String] {
                events.compactMap {
                    if case .entryMark(let role, let id) = $0 {
                        return "\(role):\(id)"
                    }
                    return nil
                }
            }
            let loaded = OmpSessionStore.parse(raw)
            check(roles(loaded.events) == ["user:u1", "agent:a1", "user:u2",
                                           "agent:a2", "agent:a3"],
                  "store parse keeps every entry mark in file order")
            check(roles(OmpSessionStore.freshEntryMarks(from: loaded, known: []))
                    == ["agent:a2", "user:u2", "agent:a1", "user:u1"],
                  "cold stamp ships content-backed marks newest-first, error tail gated out")
            check(roles(OmpSessionStore.freshEntryMarks(from: loaded,
                                                        known: ["u1", "a1"]))
                    == ["agent:a2", "user:u2"],
                  "settled turns never re-ship their marks")
            check(OmpSessionStore.freshEntryMarks(from: loaded,
                                                  known: ["u1", "a1", "u2", "a2", "a3"]).isEmpty,
                  "fully-marked store stamps nothing")
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

        print("— subagent roster (omp payload frames) —")
        // omp wraps roster data in `payload` (RpcSubagent*Frame); the
        // old top-level extraction silently dropped EVERY subagent
        // frame — the dock stayed empty while agents ran (2026-09-02).
        let saMapper = PiFrameMapper(terminalOnAgentEnd: true)
        let saLife = saMapper.map([
            "type": "subagent_lifecycle",
            "payload": ["id": "task-1", "agent": "ChA",
                        "description": "写第 1 章", "status": "started"]
                as [String: Any]])
        check(saLife.contains {
            if case .subagentUpdate(let u) = $0 {
                return u.id == "task-1" && u.state == "started"
                    && (u.detail ?? "").contains("写第 1 章")
            }
            return false
        }, "lifecycle payload unwrapped: id/status/description reach the roster")
        let saProg = saMapper.map([
            "type": "subagent_progress",
            "payload": ["agent": "ChA", "task": "第 1 章",
                        "progress": ["id": "task-1", "status": "running",
                                     "currentTool": "Edit"]
                    as [String: Any]] as [String: Any]])
        check(saProg.contains {
            if case .subagentUpdate(let u) = $0 {
                return u.id == "task-1" && u.state == "running"
                    && (u.detail ?? "").contains("Edit")
            }
            return false
        }, "progress id dug out of the nested AgentProgress object")
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

        // Store-RPC wire shapes must match the Rust structs EXACTLY —
        // the daemon decodes snake_case, and a camelCase key fails
        // from_json so silently the connection just closes (the
        // 2026-09-02 empty-remote-history report; local panes never
        // noticed because the local-store fallback masked it).
        let filePayload = SessionDaemon.storeFilePayload(sessionId: "S", store: "omp")
        check(Array(filePayload.keys.sorted()) == ["session_id", "store"],
              "SESSION_FILE payload uses the daemon's snake_case keys")
        let tailPayload = SessionDaemon.storeFilePayload(sessionId: "S", store: "omp",
                                                         tailBytes: 524_288)
        check(Array(tailPayload.keys.sorted()) == ["session_id", "store", "tail_bytes"]
              && (tailPayload["tail_bytes"] as? UInt64) == 524_288,
              "SESSION_FILE tail request carries the byte window (capability 9)")
        let forkPayload = SessionDaemon.storeForkPayload(sessionId: "S", entryId: "E")
        check(Array(forkPayload.keys.sorted()) == ["entry_id", "session_id"],
              "SESSION_FORK payload uses the daemon's snake_case keys")

        // Daemon tail seam (capability 9): the byte cut can land
        // mid-line and the file head is absent — the seam lands on the
        // first USER entry, a torn head line is skipped like any
        // non-entry line, and an old daemon's whole-file reply slices
        // through the same rule (2026-09-10: over-cap remote files
        // rendered empty while the plan still showed).
        do {
            func line(_ id: String, _ role: String) -> String {
                "{\"type\":\"message\",\"id\":\"\(id)\",\"message\":{\"role\":\"\(role)\"}}"
            }
            let whole = ["{\"type\":\"title\",\"v\":1,\"title\":\"t\"}",
                         "{\"type\":\"session\",\"version\":3,\"id\":\"s\"}",
                         line("u1", "user"), line("a1", "assistant"),
                         line("u2", "user"), line("a2", "assistant")]
                .joined(separator: "\n")
            let (slice, anchor) = OmpSessionStore.daemonTailSlice(whole)
            check(anchor == "u1" && slice.hasPrefix(line("u1", "user")),
                  "whole-file reply cuts at the first user entry, headers dropped")
            // Torn head: the cut landed inside what would have been an
            // assistant line — unparseable, skipped; the seam is u2.
            let torn = "\"role\":\"assistant\"}}\n" + whole.dropFirst(whole.utf8.count / 2)
            let (tornSlice, tornAnchor) = OmpSessionStore.daemonTailSlice(String(torn))
            check(tornAnchor == "u2" && tornSlice.hasPrefix(line("u2", "user")),
                  "torn head line is skipped, seam lands on the next user entry")
            // No user entry in the window: keep everything, no anchor.
            let assistantOnly = line("a1", "assistant") + "\n" + line("a2", "assistant")
            let (kept, keptAnchor) = OmpSessionStore.daemonTailSlice(assistantOnly)
            check(kept == assistantOnly && keptAnchor == nil,
                  "window without a user entry keeps its contents")
        }

        // pi tail-first window (omp parity): a small session renders in
        // full; a big one cuts at a USER-message boundary with an anchor
        // loadOlderHistory can page back through.
        do {
            func msg(_ id: String, _ role: String, _ text: String, _ bytes: Int)
                    -> PiLegacySession.ReplayedMessage {
                PiLegacySession.ReplayedMessage(
                    id: id, role: role,
                    events: role == "user" ? [.userMessage(text)] : [.messageChunk(text)],
                    budget: bytes)
            }
            let small = [msg("u1", "user", "hi", 10), msg("a1", "assistant", "hello", 20)]
            let whole = PiLegacySession.tailWindow(small, budget: 100)
            check(whole.anchor == nil && whole.events.count == 2,
                  "small pi session renders whole (no truncation)")
            // u1/a1 … u5/a5, each turn ~90 bytes, budget 200 → keeps the
            // last ~2 turns, cut at u4 (a user boundary, not mid-turn).
            var big: [PiLegacySession.ReplayedMessage] = []
            for i in 1...5 {
                big.append(msg("u\(i)", "user", "q\(i)", 40))
                big.append(msg("a\(i)", "assistant", "answer\(i)", 50))
            }
            let window = PiLegacySession.tailWindow(big, budget: 200)
            check(window.anchor == "u4",
                  "big pi session cuts at a user-message boundary (got \(String(describing: window.anchor)))")
            let texts = window.events.compactMap { event -> String? in
                if case .userMessage(let t) = event { return t }
                if case .messageChunk(let t) = event { return t }
                return nil
            }
            check(texts == ["q4", "answer4", "q5", "answer5"],
                  "tail window keeps exactly the recent turns (got \(texts))")
        }
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

        // ——— state migration: agent pane kind loss (2026-09-09) ———
        // A deployed interim build rewrote pane records without their
        // kind, so webview agent tabs restored as TERMINALS attached to
        // their pane's omp rpc-ui process — raw JSON instead of the GUI.
        // paneCommand is set only by the agent creation flows; a
        // terminal-kind first pane under an agent paneCommand is a
        // corrupted agent pane and must migrate back.
        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("goty-kind-loss-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("state.json")
            let pane = { (id: String, kind: String) -> String in
                "{\"id\":\"\(id)\",\"kind\":\(kind),\"cwd\":\"/x\",\"left\":0,\"top\":0,\"width\":1,\"height\":1}"
            }
            let term = #"{"terminal":{}}"#
            let agentOmp = #"{"agent":{"_0":"omp"}}"#
            let state = """
            {"focusedIndex":0,"parked":[],"workspaces":[{"auxTerminalPanes":[],"tabs":[
            {"id":"t1","name":"omp","paneCommand":"omp","panes":[\(pane("p1", term))]},
            {"id":"t2","name":"1","panes":[\(pane("p2", term))]},
            {"id":"t3","name":"omp","paneCommand":"omp","panes":[\(pane("p3", agentOmp))]}
            ],"focusedTabIndex":0,"name":"goty","sshHost":null,"id":"11111111-1111-1111-1111-111111111111"}]}
            """
            try state.write(to: file, atomically: true, encoding: .utf8)
            let store = WorkspaceStore(sessionName: "test", fileURL: file)
            let tabs = store.workspaces[0].tabs
            check(tabs.count == 3 && tabs[0].panes[0].kind == .agent("omp"),
                  "kind-lost omp tab migrates back to agent pane")
            check(tabs[1].panes[0].kind == .terminal,
                  "plain terminal tab (no paneCommand) stays terminal")
            check(tabs[2].panes[0].kind == .agent("omp"),
                  "healthy agent tab passes through untouched")
            try? FileManager.default.removeItem(at: dir)
        } catch {
            check(false, "kind-loss fixture threw: \(error)")
        }

        // RuntimeMode mapping parity (monocode codexProtocol.ts:20 /
        // claudeProtocol.ts:244; paseo claude control-plane notes).
        check(RuntimeModeMapping.codexParams(.supervised)["approvalPolicy"] as? String == "untrusted"
              && (RuntimeModeMapping.codexParams(.supervised)["sandboxPolicy"] as? [String: Any])?["type"] as? String == "readOnly"
              && RuntimeModeMapping.codexParams(.supervised)["approvalsReviewer"] as? String == "user",
              "runtimeMode supervised → codex untrusted/read-only/user reviewer")
        check(RuntimeModeMapping.codexParams(.autoEdits)["approvalPolicy"] as? String == "on-request"
              && (RuntimeModeMapping.codexParams(.autoEdits)["sandboxPolicy"] as? [String: Any])?["type"] as? String == "workspaceWrite",
              "runtimeMode autoEdits → codex on-request/workspace-write")
        check(RuntimeModeMapping.codexParams(.auto)["approvalsReviewer"] as? String == "auto_review",
              "runtimeMode auto → codex auto_review reviewer")
        check(RuntimeModeMapping.codexParams(.fullAccess)["approvalPolicy"] as? String == "never"
              && (RuntimeModeMapping.codexParams(.fullAccess)["sandboxPolicy"] as? [String: Any])?["type"] as? String == "dangerFullAccess",
              "runtimeMode fullAccess → codex never/danger-full-access")
        let threadP = RuntimeModeMapping.codexThreadParams(.autoEdits)
        check(threadP["sandbox"] as? String == "workspace-write"
              && threadP["approvalPolicy"] as? String == "on-request",
              "codexThreadParams adds the thread/start string sandbox")
        check(RuntimeModeMapping.claudeSpawn(.supervised).mode == "default"
              && RuntimeModeMapping.claudeSpawn(.supervised).extraArgs.isEmpty
              && RuntimeModeMapping.claudeSpawn(.autoEdits).mode == "acceptEdits"
              && RuntimeModeMapping.claudeSpawn(.autoEdits).extraArgs.isEmpty
              && RuntimeModeMapping.claudeSpawn(.auto).mode == "auto",
              "claudeSpawn maps supervised/autoEdits/auto to permission modes")
        let bypass = RuntimeModeMapping.claudeSpawn(.fullAccess)
        check(bypass.mode == "bypassPermissions"
              && bypass.extraArgs == ["--allow-dangerously-skip-permissions"],
              "claudeSpawn fullAccess needs the bypass flag")
        check(AgentRuntimeMode.allCases.allSatisfy { !$0.displayName.isEmpty && !$0.hint.isEmpty },
              "every runtime mode has display name and hint")

        // codex adapter: the tier rides every turn/start (no mid-session
        // mode API — monocode's per-turn resend) and the chip contract
        // matches the declared capability.
        let tp = CodexSession.turnParams(threadId: "t1", text: "hi",
                                         model: nil, mode: .auto, effort: nil,
                                         serviceTier: nil)
        check(tp["threadId"] as? String == "t1"
              && (tp["input"] as? [[String: Any]])?.first?["text"] as? String == "hi"
              && tp["approvalPolicy"] as? String == "on-request"
              && (tp["sandboxPolicy"] as? [String: Any])?["type"] as? String == "workspaceWrite"
              && tp["approvalsReviewer"] as? String == "auto_review"
              && tp["model"] == nil && tp["serviceTier"] == nil,
              "codex turnParams carries the runtime mode without a model")
        check(CodexSession.turnParams(threadId: "t", text: "x", model: "gpt-5.3",
                                      mode: .fullAccess, effort: nil,
                                      serviceTier: "fast")["serviceTier"] as? String == "fast",
              "codex turnParams carries the picked model and service tier")

        // Slash skill execution = paseo's shape: a structured skill
        // entry FIRST, then the text rewritten as a $name mention. The
        // app-server reads SKILL.md itself — the host injects nothing.
        let skillTurn = CodexSession.turnParams(
            threadId: "t", text: "$deploy staging now",
            model: nil, mode: .auto, effort: nil, serviceTier: nil,
            skill: (name: "deploy", path: "/w/.agents/skills/deploy/SKILL.md"))
        let skillInput = skillTurn["input"] as? [[String: Any]] ?? []
        check(skillInput.count == 2
              && skillInput[0]["type"] as? String == "skill"
              && skillInput[0]["name"] as? String == "deploy"
              && skillInput[0]["path"] as? String == "/w/.agents/skills/deploy/SKILL.md"
              && skillInput[1]["type"] as? String == "text"
              && skillInput[1]["text"] as? String == "$deploy staging now",
              "slash skill rides turn input as a structured entry + $mention text")

        // Command directory = the agent's OWN skills/list declaration
        // (paseo loadSkills / happier pluginAndSkillCatalog): disabled
        // skills never list, multiple skill roots dedupe by name, and
        // the host fabricates no builtin entries.
        let catalog = CodexSession.parseSkillCatalog(groups: [
            ["cwd": "/w", "skills": [
                ["name": "deploy", "description": "Deploy the app",
                 "path": "/w/.agents/skills/deploy/SKILL.md", "enabled": true],
                ["name": "paseo", "description": "Shared",
                 "path": "/w/.codex/skills/paseo/SKILL.md", "enabled": true],
            ]],
            ["cwd": "/home/u", "skills": [
                ["name": "paseo", "description": "User copy",
                 "path": "/home/u/.agents/skills/paseo/SKILL.md", "enabled": true],
                ["name": "disabled-skill", "path": "/x/SKILL.md", "enabled": false],
            ]],
        ])
        check(catalog.count == 2
              && catalog[0].name == "deploy"
              && catalog[0].description == "Deploy the app"
              && catalog[0].skillPath == "/w/.agents/skills/deploy/SKILL.md"
              && catalog.filter { $0.name == "paseo" }.count == 1,
              "skills/list catalog: enabled only, deduped across roots, path kept")
        // The directory = the TUI's OWN slash menu (codex-rs
        // slash_command.rs, release-visible set, enum order = popup
        // order). Skills are NOT flattened in — they live under
        // /skills and trigger with $name mentions.
        let tui = CodexSession.tuiCommands()
        check(tui.count == 56
              && tui[0].name == "model"
              && tui.map(\.name).contains("goal")
              && tui.map(\.name).contains("rename")
              && tui.map(\.name).contains("skills")
              && tui.map(\.name).contains("compact")
              && tui[0].name < tui[tui.count - 1].name,
              "codex / menu mirrors the TUI command table (goal, rename, skills in; source order)")
        check(tui.first { $0.name == "goal" }?.inputHint == "<objective>|pause|resume|clear"
              && tui.first { $0.name == "rename" }?.description == "rename the current thread",
              "goal carries its subcommand hint; descriptions are the TUI's own")

        // /goal frames (paseo's GoalSubcommand → thread/goal/* RPCs).
        let goalSet = CodexSession.goalParams(threadId: "t", args: "ship it")
        check(goalSet?.method == "thread/goal/set"
              && goalSet?.params["objective"] as? String == "ship it"
              && goalSet?.params["status"] as? String == "active",
              "goal <objective> sets an active goal")
        check(CodexSession.goalParams(threadId: "t", args: "pause")?.params["status"]
                as? String == "paused"
              && CodexSession.goalParams(threadId: "t", args: "clear")?.method
                == "thread/goal/clear"
              && CodexSession.goalParams(threadId: "t", args: "") == nil,
              "goal pause/clear map to their RPCs; bare goal asks for usage")
        // Attach rebuild: thread/loaded/list discovers the live thread
        // (the ring replay's orphan result only survives 16MB).
        check(CodexSession.pickLoadedThreadId(["data": ["thread-7"]]) == "thread-7"
              && CodexSession.pickLoadedThreadId(["data": []]) == nil
              && CodexSession.pickLoadedThreadId(["data": ["", "x"]]) == "x",
              "loaded/list picker takes the first non-empty live thread id")
        // codex auto-titles can swallow whole conversations (46,635
        // chars probed in state_5.sqlite on 5090) — clamp to one line.
        let long = String(repeating: "对话内容", count: 100)
        check(DaemonSessionRow.clampedTitle(long)?.count == 81
              && DaemonSessionRow.clampedTitle(long)?.hasSuffix("…") == true
              && DaemonSessionRow.clampedTitle("第一行\n第二行很长很长") == "第一行"
              && DaemonSessionRow.clampedTitle(nil) == nil
              && DaemonSessionRow.clampedTitle("  \n  ") == nil
              && DaemonSessionRow.clampedTitle("继续完善球员身份判定")
                  == "继续完善球员身份判定",
              "session title clamps to one 80-char line")

        // History replay uses a FRESH mapper: the live instance's dedupe
        // sets hold the ring-replayed ids and would swallow the whole
        // transcript (the "only error lines" history bug).
        let itemParams: [String: Any] = [
            "item": ["id": "i1", "type": "userMessage",
                     "content": [["type": "text", "text": "正文"]]] as [String: Any]]
        let liveMapper = CodexFrameMapper()
        _ = liveMapper.map(method: "item/completed", params: itemParams)
        check(liveMapper.map(method: "item/completed", params: itemParams).isEmpty
              && CodexFrameMapper().map(method: "item/completed", params: itemParams).count == 1,
              "a deduped live mapper drops the replay; a fresh instance emits it")
        // Custom prompts: ~/.codex/prompts/*.md, name prefixed
        // "prompts:", frontmatter feeds description + argument-hint.
        let promptHome = NSTemporaryDirectory() + "/goty-codexhome-\(UUID().uuidString.prefix(6))"
        let promptDir = promptHome + "/prompts"
        try? FileManager.default.createDirectory(atPath: promptDir,
                                                 withIntermediateDirectories: true)
        try? #"""
        ---
        description: Apply an OpenSpec proposal
        argument-hint: <proposal>
        ---
        Apply $1 with care. Args: $ARGUMENTS. Cost $$5. Opt $2.
        """#.write(toFile: promptDir + "/openspec-apply.md",
                  atomically: true, encoding: .utf8)

        // Live user-echo suppression (pi-mono rule): the composer echoes
        // optimistically, the agent's userMessage echo must not re-render.
        let echoItem: [String: Any] = [
            "id": "u1",
            "type": "userMessage",
            "content": [["type": "text", "text": " 你好 "]],
        ]
        let agentItem: [String: Any] = [
            "id": "a1",
            "type": "agentMessage",
            "text": "你好",
        ]
        check(CodexSession.liveEchoIndex(pending: ["你好"],
                                         params: ["item": echoItem]) == 0
              && CodexSession.liveEchoIndex(pending: ["别的"],
                                            params: ["item": echoItem]) == nil
              && CodexSession.liveEchoIndex(pending: ["你好"],
                                            params: ["item": agentItem]) == nil,
              "userMessage echo matches a pending sent text; other types never do")
        let prompts = CodexSession.scanCustomPrompts(
            codexHome: (promptDir as NSString).deletingLastPathComponent)
            .filter { $0.name == "prompts:openspec-apply" }
        check(prompts.count == 1
              && prompts[0].description == "Apply an OpenSpec proposal"
              && prompts[0].inputHint == "<proposal>",
              "prompts scan reads frontmatter and prefixes the name")
        let expanded = CodexSession.expandCustomPrompt(
            template: "Apply $1 with care. Args: $ARGUMENTS. Cost $$5. Opt $2.",
            args: "alpha beta")
        check(expanded == "Apply alpha with care. Args: alpha beta. Cost $5. Opt beta.",
              "prompt expansion: $1/$2/$ARGUMENTS/$$ per codex rules")
        check(CodexSession.expandCustomPrompt(
                template: "Branch $branch", args: "branch=main") == "Branch main",
              "prompt expansion: named key=value substitutes $key")
        check(CodexSession.stripFrontMatter(
                "---\ndescription: x\n---\nBody line.") == "Body line.",
              "frontmatter strip leaves the body")

        // matchSkill: $name rest → the agent-declared skill (the TUI
        // mention syntax); slash and unknown tokens are not skills.
        let dir = [AgentSlashCommand(name: "deploy", description: nil,
                                     inputHint: nil,
                                     skillPath: "/w/deploy/SKILL.md")]
        let m = CodexSession.matchSkill("$deploy staging now", commands: dir)
        check(m?.command.name == "deploy" && m?.rest == "staging now",
              "matchSkill splits $name and trailing args")
        check(CodexSession.matchSkill("$native", commands: dir) == nil,
              "unknown $mention is not a skill — text reaches the agent verbatim")
        let modeOption = CodexSession.runtimeModeOption(current: .autoEdits)
        check(modeOption.id == "runtimeMode" && modeOption.name == "权限"
              && modeOption.currentValue == "autoEdits"
              && modeOption.options.count == AgentRuntimeMode.allCases.count
              && modeOption.options.allSatisfy { choice in
                  AgentRuntimeMode(rawValue: choice.value) != nil
              },
              "codex runtimeMode option lists every tier as a choice")

        // claude adapter: mid-session permission-mode switch over the
        // control protocol (paseo setPermissionMode parity) + cold
        // respawn carries the mode as a spawn arg.
        let (_, autoEditArgs) = ClaudeSession.shellCommand(model: nil, resume: nil,
                                                           mode: .autoEdits)
        check(autoEditArgs[1].contains("--permission-mode acceptEdits"),
              "claude spawn carries --permission-mode acceptEdits")
        let (_, bypassArgs) = ClaudeSession.shellCommand(model: nil, resume: nil,
                                                         mode: .fullAccess)
        check(bypassArgs[1].contains("--permission-mode bypassPermissions")
              && bypassArgs[1].contains("--allow-dangerously-skip-permissions"),
              "claude bypass spawn carries the mode and its danger flag")
        let modeFrame = ClaudeSession.setPermissionModeFrame(.auto)
        check(modeFrame["type"] as? String == "control_request"
              && (modeFrame["request"] as? [String: Any])?["subtype"] as? String == "set_permission_mode"
              && (modeFrame["request"] as? [String: Any])?["mode"] as? String == "auto"
              && !(modeFrame["request_id"] as? String ?? "").isEmpty,
              "claude setPermissionModeFrame shapes the control request")

        // codex thinking knob: effort rides turn/start like the model.
        let tpEffort = CodexSession.turnParams(threadId: "t", text: "hi",
                                               model: nil, mode: .auto,
                                               effort: "high", serviceTier: nil)
        check(tpEffort["effort"] as? String == "high",
              "codex turnParams carries the reasoning effort")
        let noEffort = CodexSession.turnParams(threadId: "t", text: "hi",
                                                model: nil, mode: .auto,
                                                effort: nil, serviceTier: nil)
        check(noEffort["effort"] == nil,
              "codex turnParams omits effort when unset (codex default)")
        let thinking = CodexSession.thinkingOption(current: "medium")
        check(thinking.id == "thinking" && thinking.name == "思考"
              && thinking.currentValue == "medium"
              && thinking.options.contains { $0.value == "xhigh" }
              && thinking.options.count == 5,
              "codex thinking option lists all five efforts")

        // adapter that declares .runtimeModes must surface the chip
        // contract (runtimeMode option), and one that doesn't must
        // never emit it.
        check(CodexSession.declaredCapabilities.contains(.runtimeModes),
              "codex declares .runtimeModes")
        check(ClaudeSession.declaredCapabilities.contains(.runtimeModes),
              "claude declares .runtimeModes")
        check(!PiSession.declaredCapabilities.contains(.runtimeModes)
              && !OmpSession.declaredCapabilities.contains(.runtimeModes),
              "pi/omp do not claim runtime modes (their approvals are the extension dialogs)")
        check(RuntimeModeMapping.option(current: .supervised).id == "runtimeMode"
              && RuntimeModeMapping.option(current: .supervised).options.count == 4,
              "shared runtimeMode option builder serves every declaring adapter")

        // RemoteDaemonLink binary-drift detection: the capability
        // number can't see a same-capability binary swap (2026-09-11,
        // host 5090: cap-9 daemon from an older build served omp rows
        // to store:"codex"). The RUNNING binary's argv names its hash.
        check(RemoteDaemonLink.runningBinaryMatches(
                  pgrepOutput: "3686206 ./goty-sessiond-71b0bf256657 /root/.local/share/goty/sessiond.sock\n",
                  expectedName: "goty-sessiond-71b0bf256657"),
              "running binary hash equal → match")
        check(!RemoteDaemonLink.runningBinaryMatches(
                  pgrepOutput: "2999353 /root/.local/share/goty/bin/goty-sessiond-eacff6e75420 /root/.local/share/goty/sessiond.sock",
                  expectedName: "goty-sessiond-71b0bf256657"),
              "running binary hash differs → drift")
        check(RemoteDaemonLink.runningBinaryMatches(
                  pgrepOutput: "",
                  expectedName: "goty-sessiond-71b0bf256657"),
              "no pgrep output (daemon argv unreadable) → treat as match")
        check(RemoteDaemonLink.runningBinaryMatches(
                  pgrepOutput: "1234 bash -c pgrep -af [g]oty-sessiond\n",
                  expectedName: "goty-sessiond-71b0bf256657"),
              "only self-matching shells in output → no daemon line, match")

        try? FileManager.default.removeItem(atPath: samplePath)
        if failures > 0 { exit(1) }
        print("agenttest: all passed")
    }
}

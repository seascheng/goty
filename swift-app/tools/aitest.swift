// aitest.swift — headless tests for Core AI types (Task 1+).
import Foundation

@main enum AITest {
    static func main() {
        var failures = 0
        func check(_ cond: Bool, _ name: String) {
            if cond { print("  ok  \(name)") } else { failures += 1; print("FAIL  \(name)") }
        }
        let target = ExecutionTarget(
            workspaceId: UUID(), paneId: "p1", displayName: "Local",
            transport: .local, cwd: "/tmp", shell: "/bin/zsh")
        check(target == target, "ExecutionTarget equatable")
        check(target.transport != .ssh(host: "h"), "transport inequality")

        let p1 = AIProposal(op: .bash("mv a b"), explanation: "e", risk: .mutating, rollbackHint: nil)
        let p2 = AIProposal(op: .bash("mv a b"), explanation: "other", risk: .mutating, rollbackHint: nil)
        check(p1.fingerprint == p2.fingerprint, "fingerprint ignores explanation")
        check(p1.fingerprint != AIProposal(op: .bash("mv a c"), explanation: "e", risk: .mutating, rollbackHint: nil).fingerprint,
              "fingerprint covers command")

        var task = AITask(context: AIContext(request: "r", target: target, visibleOutput: "", hostFacts: ""))
        check(task.phase == .idle && task.budgetRemaining == 25, "task initial state")
        task.append(round: AIRound(reasoning: nil, toolName: "read", toolInput: "{}", toolResult: "x"))
        check(task.rounds.count == 1, "round appended")
        check(task.spendRound() && task.budgetRemaining == 24, "budget decrements")
        task.setPending(p1); task.advance(to: .awaitingConfirmation)
        check(task.pendingProposal == p1 && task.phase == .awaitingConfirmation, "proposal set")

        print("— ReadOnlyPolicy —")
        check(ReadOnlyPolicy.autoExecutable("pwd"), "pwd auto")
        check(ReadOnlyPolicy.autoExecutable("ls -la"), "ls args auto")
        check(ReadOnlyPolicy.autoExecutable("find . -maxdepth 1 -name '*.txt'"), "find safe auto")
        check(!ReadOnlyPolicy.autoExecutable("find . -name x -delete"), "find -delete blocked")
        check(!ReadOnlyPolicy.autoExecutable("find . -exec rm {} ;"), "find -exec blocked")
        check(ReadOnlyPolicy.autoExecutable("git status"), "git status auto")
        check(ReadOnlyPolicy.autoExecutable("git diff HEAD~1"), "git diff auto")
        check(!ReadOnlyPolicy.autoExecutable("git push"), "git push not auto")
        check(!ReadOnlyPolicy.autoExecutable("env"), "env blocked (secret leak)")
        check(!ReadOnlyPolicy.autoExecutable("cat x | sh"), "pipe blocked")
        check(!ReadOnlyPolicy.autoExecutable("ls > out"), "redirect blocked")
        check(!ReadOnlyPolicy.autoExecutable("ls; rm -rf /"), "semicolon blocked")
        check(!ReadOnlyPolicy.autoExecutable("echo `whoami`"), "backtick blocked")
        check(!ReadOnlyPolicy.autoExecutable("echo $(whoami)"), "cmdsub blocked")
        check(!ReadOnlyPolicy.autoExecutable("sudo ls"), "sudo never auto")
        check(ReadOnlyPolicy.classify("rm -rf x") == .destructive, "rm destructive")
        check(ReadOnlyPolicy.classify("mv a b") == .mutating, "mv mutating")
        check(ReadOnlyPolicy.classify("git reset --hard") == .destructive, "git reset destructive")
        check(ReadOnlyPolicy.classify("pwd") == .readOnly, "pwd readonly")
        check(!ReadOnlyPolicy.autoExecutable(""), "empty not auto")

        print("— Executors —")
        let sem = DispatchSemaphore(value: 0)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("goty-ai-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let local = LocalExecutor()
        local.run("echo hello", cwd: tmp, timeout: 10) { r in
            if case .success(let e) = r, e.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello" {
                check(true, "local echo runs")
            } else { check(false, "local echo runs") }
            sem.signal()
        }
        sem.wait()
        local.write(path: tmp + "/f.txt", content: "alpha beta") { r in
            check((try? String(contentsOfFile: tmp + "/f.txt", encoding: .utf8)) == "alpha beta", "local write")
            sem.signal()
        }
        sem.wait()
        local.edit(path: tmp + "/f.txt", oldText: "beta", newText: "gamma") { r in
            check((try? String(contentsOfFile: tmp + "/f.txt", encoding: .utf8)) == "alpha gamma", "local edit")
            sem.signal()
        }
        sem.wait()
        local.edit(path: tmp + "/f.txt", oldText: "nope", newText: "x") { r in
            if case .failure(.editAnchorNotFound) = r { check(true, "edit missing anchor fails") }
            else { check(false, "edit missing anchor fails") }
            sem.signal()
        }
        sem.wait()
        // SSH command construction is pure; no live ssh in tests.
        check(SSHExecutor(host: "example.invalid") is CommandExecutor, "ssh executor type exists")

        print("— LineTrigger —")
        var fired: [String] = []
        let lt = LineTrigger()
        lt.onTrigger = { fired.append($0) }
        func type(_ s: String) { _ = lt.filter(Array(s.utf8)) }
        lt.armed = true
        type("echo \"@ai x\"\r")
        check(fired.isEmpty, "mid-line @ai not triggered")
        type("echo hi\r")
        type("@ai rename files\r")
        check(fired == ["rename files"], "line-leading @ai triggers, enter swallowed")
        _ = lt.filter([0x15])                       // ctrl-u
        lt.armed = false
        type("@ai nope\r")
        check(fired.count == 1, "unarmed passes through")
        lt.armed = true
        type("@ai fix nam")                         // backspace mid-word
        _ = lt.filter([0x7F])
        type("me\r")
        check(fired.last == "fix name", "backspace tracked")
        type("@ai a\u{7F}\u{7F}\u{7F}x\r")
        check(fired.last == "x", "backspace at line start clamps")
        type("@ai ab")                              // ctrl-c aborts the line
        _ = lt.filter([0x03])
        type("plain\r")
        check(fired.last == "x", "ctrl-c resets accumulator")
        type("@ai  spaced  \r")
        check(fired.last == "spaced", "request trimmed")
        _ = lt.filter([0x03])
        // Arrow keys (CSI and SS3 forms) must not feed the line: the
        // trailing letter used to land in the buffer and break the
        // prefix match on the next typed line (the field-reported
        // "works once, then command not found" bug).
        _ = lt.filter([0x1B, 0x5B, 0x41])   // CSI up
        _ = lt.filter([0x1B, 0x4F, 0x41])   // SS3 up
        type("@ai after arrows\r")
        check(fired.last == "after arrows", "arrow keys do not pollute the line")
        _ = lt.filter([0x1B, 0x5B, 0x31, 0x7E, 0x1B, 0x5B, 0x33, 0x7E])   // Home + Delete
        type("@ai home delete ok\r")
        check(fired.last == "home delete ok", "home/delete keys pass through cleanly")
        // IME compatibility: paired-symbol '@@' (e.g. macOS Chinese IMEs
        // emitting '@' as a pair) and a missing space after the prefix.
        type("@@ai 配对符号模式\r")
        check(fired.last == "配对符号模式", "paired @@ trigger matches (IME)")
        type("@ai无空格请求\r")
        check(fired.last == "无空格请求", "no-space prefix still triggers (IME)")
        type("@@ai无空格配对\r")
        check(fired.last == "无空格配对", "paired @@ with no space triggers (IME)")
        type("@ai\r")
        check(fired.last == "无空格配对", "bare @ai with no request does not trigger")
        type("echo @ai mid-line\r")
        check(fired.last == "无空格配对", "mid-line @ai still does not trigger")

        print("— OutputTail —")
        let tail = OutputTail()
        tail.append(Array("\u{1B}[32mOK\u{1B}[0m\n\u{1B}]0;title\u{7}\nplain line\n".utf8))
        check(tail.snapshot.contains("OK") && tail.snapshot.contains("plain line")
              && !tail.snapshot.contains("[32m") && !tail.snapshot.contains("]0;"), "ANSI/OSC stripped")
        for n in 0..<200 { tail.append(Array("line \(n)\n".utf8)) }
        check(tail.snapshot.contains("line 199") && !tail.snapshot.contains("line 100"), "ring keeps only the tail")
        let big = OutputTail()
        big.append(Array(String(repeating: "x", count: 20_000).utf8))
        check(big.snapshot.count <= 9_000, "8KB cap holds")

        print("— ModelClient —")
        check(OpenAICompatibleClient(baseUrl: "", apiKey: "k", model: "m")
              .buildRequestBody(messages: [ChatMessage(role: "user", content: "hi", toolCalls: nil, toolCallId: nil)],
                                tools: []).contains("\"messages\""), "request body encodes")
        let sample = """
        {"choices":[{"message":{"role":"assistant","content":null,
         "tool_calls":[{"id":"c1","type":"function",
           "function":{"name":"bash","arguments":"{\\"command\\":\\"pwd\\"}"}}]}}]}
        """
        let reply = OpenAICompatibleClient.parse(data: Data(sample.utf8))
        check(reply?.toolCalls.first?.name == "bash"
              && reply?.toolCalls.first?.argumentsJSON.contains("pwd") == true, "tool_calls parsed")
        let plain = OpenAICompatibleClient.parse(data: Data(
            "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"done\"}}]}".utf8))
        check(plain?.text == "done" && plain?.toolCalls.isEmpty == true, "plain reply parsed")

        // anthropic-messages shaping: system hoisted, tool_use/tool_result blocks
        let aBody = OpenAICompatibleClient.buildAnthropicBody(
            model: "m", messages: [
                ChatMessage(role: "system", content: "sys prompt", toolCalls: nil, toolCallId: nil),
                ChatMessage(role: "user", content: "list files", toolCalls: nil, toolCallId: nil),
                ChatMessage(role: "assistant", content: "thinking",
                            toolCalls: [ToolCall(id: "t1", name: "bash", argumentsJSON: "{\"command\":\"ls\"}")], toolCallId: nil),
                ChatMessage(role: "tool", content: "file-a", toolCalls: nil, toolCallId: "t1"),
            ], tools: [ToolSpec(name: "bash", description: "run", parametersJSON: "{\"type\":\"object\"}")])
        check(aBody.contains("\"system\":\"sys prompt\""), "anthropic system hoisted")
        check(aBody.contains("\"tool_use\""), "anthropic tool_use block")
        check(aBody.contains("\"tool_result\""), "anthropic tool_result block")
        check(aBody.contains("\"input_schema\""), "anthropic tool schema")
        let aSample = """
        {"content":[{"type":"text","text":"about to run"},{"type":"tool_use","id":"c9","name":"bash","input":{"command":"pwd"}}],"stop_reason":"tool_use"}
        """
        let aReply = OpenAICompatibleClient.parseAnthropic(data: Data(aSample.utf8))
        check(aReply?.text == "about to run" && aReply?.toolCalls.first?.name == "bash"
              && aReply?.toolCalls.first?.argumentsJSON.contains("pwd") == true, "anthropic reply parsed")
        check(OpenAICompatibleClient.parseAnthropic(data: Data("{\"content\":[]}".utf8)) == nil,
              "anthropic empty content rejected")

        print("— AITaskCoordinator loop —")
        final class FakeModel: ModelClient {
            var script: [[ToolCall]] = []
            var finalText = "done"
            var calls = 0
            func complete(messages: [ChatMessage], tools: [ToolSpec],
                          completion: @escaping (Result<ModelReply, ModelError>) -> Void) {
                let idx = calls; calls += 1
                if idx < script.count {
                    completion(.success(ModelReply(text: nil, toolCalls: script[idx])))
                } else {
                    completion(.success(ModelReply(text: finalText, toolCalls: [])))
                }
            }
        }
        final class FakeExec: CommandExecutor {
            var ran: [String] = []
            var wrote: [String] = []
            func run(_ c: String, cwd: String?, timeout: TimeInterval,
                     completion: @escaping (Result<ExecResult, ExecFailure>) -> Void) {
                ran.append(c)
                completion(.success(ExecResult(exitCode: 0, stdout: "out:\(c)", stderr: "")))
            }
            func read(path: String, completion: @escaping (Result<String, ExecFailure>) -> Void) {
                completion(.success("file-content"))
            }
            func write(path: String, content: String,
                       completion: @escaping (Result<ExecResult, ExecFailure>) -> Void) {
                wrote.append(path)
                completion(.success(ExecResult(exitCode: 0, stdout: "", stderr: "")))
            }
            func edit(path: String, oldText: String, newText: String,
                      completion: @escaping (Result<ExecResult, ExecFailure>) -> Void) {
                completion(.success(ExecResult(exitCode: 0, stdout: "", stderr: "")))
            }
        }
        // onUpdate fires on the MAIN queue — waits must spin the runloop
        // to service it. Every wait is time-bounded; timeout = failure.
        func waitSem(_ s: DispatchSemaphore, timeout: TimeInterval = 10) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if s.wait(timeout: .now()) == .success { return true }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            return s.wait(timeout: .now()) == .success
        }

        // probe → proposal → confirm → verify → completed
        do {
            let m = FakeModel()
            let e = FakeExec()
            let awaitSem = DispatchSemaphore(value: 0)
            let doneSem = DispatchSemaphore(value: 0)
            var last: AITask?
            let coord = AITaskCoordinator(model: m, executorFor: { _ in e })
            coord.onUpdate = { t in
                last = t
                if t.phase == .awaitingConfirmation { awaitSem.signal() }
                if case .completed = t.phase { doneSem.signal() }
                if case .failed = t.phase { doneSem.signal() }
            }
            m.script = [
                [ToolCall(id: "1", name: "bash", argumentsJSON: "{\"command\":\"ls\"}")],
                [ToolCall(id: "2", name: "bash", argumentsJSON: "{\"command\":\"mv a b\"}")],
                [ToolCall(id: "3", name: "bash", argumentsJSON: "{\"command\":\"ls\"}")],
            ]
            let tid = coord.start(context: AIContext(request: "rename", target: target,
                                                      visibleOutput: "", hostFacts: ""))
            check(waitSem(awaitSem), "reaches awaitingConfirmation")
            check(last?.pendingProposal?.op == .bash("mv a b"), "mutation became proposal")
            check(e.ran.contains("ls"), "allowlisted probe ran without confirm")
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.3))
            check(!e.ran.contains("mv a b"), "no execution before confirm")
            coord.confirm(taskId: tid)
            check(waitSem(doneSem), "completes after confirm")
            check(e.ran.contains("mv a b"), "confirmed proposal executed")
            check(last?.rounds.count == 3, "post-exec verification round ran")
            if case .completed(let summary)? = last?.phase {
                check(summary == "done", "completed summary is model text")
            } else { check(false, "completed summary is model text") }
        }

        // edit invalidates: proposal replaced, second confirm still required
        do {
            let m = FakeModel()
            let e = FakeExec()
            let awaitSem = DispatchSemaphore(value: 0)
            let doneSem = DispatchSemaphore(value: 0)
            var last: AITask?
            let coord = AITaskCoordinator(model: m, executorFor: { _ in e })
            coord.onUpdate = { t in
                last = t
                if t.phase == .awaitingConfirmation { awaitSem.signal() }
                if case .completed = t.phase { doneSem.signal() }
                if case .failed = t.phase { doneSem.signal() }
            }
            m.script = [
                [ToolCall(id: "1", name: "bash", argumentsJSON: "{\"command\":\"mv a b\"}")],
            ]
            let tid = coord.start(context: AIContext(request: "rename", target: target,
                                                      visibleOutput: "", hostFacts: ""))
            check(waitSem(awaitSem), "second task reaches awaitingConfirmation")
            coord.edit(taskId: tid, to: AIProposal(op: .bash("mv a c"), explanation: "",
                                                  risk: .mutating, rollbackHint: nil))
            check(waitSem(awaitSem), "edit re-emits awaitingConfirmation")
            check(last?.pendingProposal?.op == .bash("mv a c"), "edit replaces pending proposal")
            check(last?.phase == .awaitingConfirmation, "phase back to awaitingConfirmation")
            check(!e.ran.contains("mv a b") && !e.ran.contains("mv a c"),
                  "edited proposal not executed yet")
            coord.confirm(taskId: tid)
            check(waitSem(doneSem), "second confirm completes")
            check(e.ran.contains("mv a c") && !e.ran.contains("mv a b"),
                  "edited command is what executes")
        }

        // budget: 30 scripted probes exhaust 25, continueBudget resumes
        do {
            let m = FakeModel()
            let e = FakeExec()
            let budgetSem = DispatchSemaphore(value: 0)
            let doneSem = DispatchSemaphore(value: 0)
            var last: AITask?
            let coord = AITaskCoordinator(model: m, executorFor: { _ in e })
            coord.onUpdate = { t in
                last = t
                if case .budgetExhausted = t.phase { budgetSem.signal() }
                if case .completed = t.phase { doneSem.signal() }
                if case .failed = t.phase { doneSem.signal() }
            }
            m.script = (0..<30).map {
                [ToolCall(id: "c\($0)", name: "bash", argumentsJSON: "{\"command\":\"ls\"}")]
            }
            let tid = coord.start(context: AIContext(request: "scan", target: target,
                                                      visibleOutput: "", hostFacts: ""))
            check(waitSem(budgetSem), "budget exhausts after 25 rounds")
            check(last?.rounds.count == 25 && last?.budgetRemaining == 0,
                  "25 rounds spent, budget zero")
            if case .budgetExhausted? = last?.phase {
                check(true, "budgetExhausted phase reached")
            } else { check(false, "budgetExhausted phase reached") }
            coord.continueBudget(taskId: tid)
            check(waitSem(doneSem), "continueBudget resumes to completion")
            // The tool call that hits the exhausted budget is consumed by
            // the gate (plan Task 7 step 4: spendRound-fail → return, the
            // request is not re-issued), so 30 scripted calls → 29 rounds.
            check(last?.rounds.count == 29, "remaining rounds run after continue")
        }

        // write tool: proposal awaits confirmation before touching disk
        do {
            let m = FakeModel()
            let e = FakeExec()
            let awaitSem = DispatchSemaphore(value: 0)
            let doneSem = DispatchSemaphore(value: 0)
            var last: AITask?
            let coord = AITaskCoordinator(model: m, executorFor: { _ in e })
            coord.onUpdate = { t in
                last = t
                if t.phase == .awaitingConfirmation { awaitSem.signal() }
                if case .completed = t.phase { doneSem.signal() }
                if case .failed = t.phase { doneSem.signal() }
            }
            m.script = [
                [ToolCall(id: "1", name: "write",
                          argumentsJSON: "{\"path\":\"/tmp/w\",\"content\":\"x\"}")],
            ]
            let tid = coord.start(context: AIContext(request: "save", target: target,
                                                      visibleOutput: "", hostFacts: ""))
            check(waitSem(awaitSem), "write proposal awaits confirmation")
            check(last?.pendingProposal == AIProposal(op: .write(path: "/tmp/w", content: "x"),
                                                     explanation: "", risk: .mutating,
                                                     rollbackHint: nil),
                  "write tool becomes .write proposal")
            check(e.wrote.isEmpty, "write not executed before confirm")
            coord.confirm(taskId: tid)
            check(waitSem(doneSem), "confirmed write completes")
            check(e.wrote == ["/tmp/w"], "write executed after confirm")
        }

        // acceptance #10 (close cancels): cancel during a pending
        // proposal must kill the task without executing anything, and
        // a late confirm on a cancelled task is inert (no zombie exec).
        do {
            let m = FakeModel()
            let e = FakeExec()
            let awaitSem = DispatchSemaphore(value: 0)
            let cancelSem = DispatchSemaphore(value: 0)
            var last: AITask?
            let coord = AITaskCoordinator(model: m, executorFor: { _ in e })
            coord.onUpdate = { t in
                last = t
                if t.phase == .awaitingConfirmation { awaitSem.signal() }
                if t.phase == .cancelled { cancelSem.signal() }
            }
            m.script = [
                [ToolCall(id: "1", name: "bash", argumentsJSON: "{\"command\":\"mv a b\"}")],
            ]
            let tid = coord.start(context: AIContext(request: "mv", target: target,
                                                      visibleOutput: "", hostFacts: ""))
            check(waitSem(awaitSem), "mutation proposal awaits before cancel")
            coord.cancel(taskId: tid)
            check(waitSem(cancelSem), "cancel transitions to .cancelled")
            check(!e.ran.contains("mv a b"), "cancelled proposal never executes")
            coord.confirm(taskId: tid)   // late UI callback after close
            Thread.sleep(forTimeInterval: 0.15)
            check(!e.ran.contains("mv a b"), "late confirm on cancelled task is inert")
        }

        exit(failures == 0 ? 0 : 1)
    }
}

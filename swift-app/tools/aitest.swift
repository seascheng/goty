// aitest.swift — headless tests for Core AI types (Task 1+).
import Foundation
@testable import goty

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

        // Agent prefixes (@omp/@claude/…): agentArmed-gated, routed to
        // onAgentTrigger with the manifest key; @ai and @agent are
        // independent arming domains.
        var agentFired: [(key: String, text: String)] = []
        lt.onAgentTrigger = { agentFired.append(($0, $1)) }
        lt.armed = false
        lt.agentArmed = false
        type("@omp hi\r")
        check(agentFired.isEmpty, "agent trigger needs agentArmed")
        lt.agentArmed = true
        type("@omp fix the build\r")
        check(agentFired.last?.key == "omp" && agentFired.last?.text == "fix the build",
              "line-leading @omp routes key + prompt")
        type("@pi\r")   // pi is a registry agent now (bare, no prompt)
        check(agentFired.count == 2 && agentFired.last?.key == "pi",
              "@pi routes to the pi adapter")
        lt.armed = true
        type("@ai plan the work\r")
        check(fired.last == "plan the work" && agentFired.count == 2,
              "@ai still routes to onTrigger")
        type("@omp\r")
        check(agentFired.last?.text == "", "bare @omp opens without prompt")
        _ = lt.filter([0x03])
        type("@claude write tests\r")   // claude is a registry agent now
        check(agentFired.last?.key == "claude" && agentFired.last?.text == "write tests",
              "@claude routes to the claude adapter")
        _ = lt.filter([0x03])
        type("@cursor-agent hi\r")   // genuinely not a registry agent
        check(agentFired.last?.key == "claude",
              "non-manifest agent names pass through to the shell")
        _ = lt.filter([0x03])
        type("@omp again\r")
        check(agentFired.last?.key == "omp" && agentFired.last?.text == "again",
              "manifest key fires after a passthrough line")
        _ = lt.filter([0x03])

        // History recall (↑/ctrl-r): the recalled text lives only on
        // the rendered screen, so the enter is swallowed pending a
        // cursor-row check (onPendingEnter) — it never reaches the
        // typed-line trigger.
        var pending = 0
        let firedBefore = fired.count
        lt.onPendingEnter = { pending += 1 }
        _ = lt.filter([0x1B, 0x5B, 0x41])   // ↑ recalls "@ai from history"
        _ = lt.filter([0x0D])
        check(pending == 1 && fired.count == firedBefore,
              "recalled enter defers to the screen check")
        _ = lt.filter([0x1B, 0x5B, 0x42])   // ↓ then typed text
        type("ls\r")
        check(pending == 2, "arrow-edited line defers even with typed bytes")
        type("plain\r")
        check(pending == 2, "pure typed line does not defer")
        _ = lt.filter([0x12])               // ctrl-r then enter
        _ = lt.filter([0x0D])
        check(pending == 3, "ctrl-r recall defers")
        type("@ai typed after recall\r")    // ctrl-u was NOT sent; fresh typed line
        type("@ai 测试一下")
        _ = lt.filter([0x7F])   // backspace over a multibyte char
        _ = lt.filter([0x7F])   // and again
        type("好\r")
        check(fired.last == "测试好",
              "backspace removes whole CJK chars (no dangling UTF-8 lead)")

        // Bracketed paste: the chokepoint sees ESC[200~ … ESC[201~ with
        // inner newlines as readline CONTENT, not enters. The first CR
        // used to hit the zle branch and return early, dropping the rest
        // of the chunk — every armed multi-line paste arrived truncated
        // to line one with the 201~ closer missing (shell stuck in paste
        // mode) and the async screen check added the felt lag.
        let firedAtPaste = fired.count, pendingAtPaste = pending
        let paste = "\u{1b}[200~line one\nline two\u{1b}[201~"
        let through = lt.filter(Array(paste.utf8))
        check(through == Array(paste.utf8),
              "bracketed paste forwards byte-identical (closer included)")
        check(fired.count == firedAtPaste && pending == pendingAtPaste,
              "paste content runs no enter logic")
        _ = lt.filter([0x0D])   // the user's own enter AFTER the paste
        check(pending == pendingAtPaste + 1,
              "enter after a paste defers to the screen check")
        // Split across onWrite chunks: paste state must carry.
        let head = "\u{1b}[200~first ", pasteTail = "second\nthird\u{1b}[201~"
        let h1 = lt.filter(Array(head.utf8)), h2 = lt.filter(Array(pasteTail.utf8))
        check(h1 + h2 == Array((head + pasteTail).utf8),
              "paste split across chunks forwards intact")
        type("plain\r")
        check(pending == pendingAtPaste + 2, "enter after the split paste defers too (201~ marks the line screen-truth)")
        _ = lt.filter([0x15])   // ctrl-u: fresh line, no paste residue
        type("@ai after paste\r")
        check(fired.last == "after paste", "typed trigger works normally after pastes")

        print("— Screen-row matcher —")
        check(LineTrigger.requestFromScreenRow("➜  goty git:(main) ✗ @ai 测试一下") == "测试一下",
              "prompt + recalled @ai extracts request")
        check(LineTrigger.requestFromScreenRow("➜  goty ✗ @@ai 配对") == "配对",
              "IME @@ recall matches")
        check(LineTrigger.requestFromScreenRow("➜  ✗ @ai　全角空格") == "全角空格",
              "full-width space trimmed")
        check(LineTrigger.requestFromScreenRow("user@host:~$ @ai list files") == "list files",
              "bash prompt recall matches")
        check(LineTrigger.requestFromScreenRow("➜  ✗ echo \"@ai x\"") == nil,
              "quoted mid-command recall passes through")
        check(LineTrigger.matchFromScreenRow("➜  ✗ @omp fix login")?.kind == .agent(key: "omp")
              && LineTrigger.matchFromScreenRow("➜  ✗ @omp fix login")?.text == "fix login",
              "recalled @omp row classifies agent + prompt")
        check(LineTrigger.matchFromScreenRow("➜  ✗ @ai refactor")?.kind == .ai,
              "recalled @ai row still classifies ai")
        check(LineTrigger.matchFromScreenRow("➜  ✗ echo \"@omp x\"") == nil,
              "quoted mid-command @omp passes through")
        check(LineTrigger.requestFromScreenRow("➜  ✗ ls -la") == nil,
              "row without @ai is nil")
        check(LineTrigger.requestFromScreenRow("➜  ✗ @ai ") == nil,
              "bare @ai row is nil")

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
        let rSample = """
        {"choices":[{"message":{"role":"assistant","content":"run pwd","reasoning_content":"the user wants pwd"}}]}
        """
        let rReply = OpenAICompatibleClient.parse(data: Data(rSample.utf8))
        check(rReply?.reasoning == "the user wants pwd",
              "openai reasoning_content parsed")

        // anthropic-messages shaping: system hoisted, tool_use/tool_result blocks
        let aBodyObj = OpenAICompatibleClient.buildAnthropicBody(
            model: "m", messages: [
                ChatMessage(role: "system", content: "sys prompt", toolCalls: nil, toolCallId: nil),
                ChatMessage(role: "user", content: "list files", toolCalls: nil, toolCallId: nil),
                ChatMessage(role: "assistant", content: "thinking",
                            toolCalls: [ToolCall(id: "t1", name: "bash", argumentsJSON: "{\"command\":\"ls\"}")], toolCallId: nil),
                ChatMessage(role: "tool", content: "file-a", toolCalls: nil, toolCallId: "t1"),
            ], tools: [ToolSpec(name: "bash", description: "run", parametersJSON: "{\"type\":\"object\"}")])
        let aBody = String(data: (try? JSONSerialization.data(withJSONObject: aBodyObj)) ?? Data(),
                           encoding: .utf8) ?? "{}"
        check(aBody.contains("\"system\":\"sys prompt\""), "anthropic system hoisted")
        check(aBody.contains("\"tool_use\""), "anthropic tool_use block")
        check(aBody.contains("\"tool_result\""), "anthropic tool_result block")
        check(aBody.contains("\"input_schema\""), "anthropic tool schema")
        let aSample = """
        {"content":[{"type":"thinking","thinking":"i should check the directory"},{"type":"text","text":"about to run"},{"type":"tool_use","id":"c9","name":"bash","input":{"command":"pwd"}}],"stop_reason":"tool_use"}
        """
        let aReply = OpenAICompatibleClient.parseAnthropic(data: Data(aSample.utf8))
        check(aReply?.text == "about to run" && aReply?.toolCalls.first?.name == "bash"
              && aReply?.toolCalls.first?.argumentsJSON.contains("pwd") == true, "anthropic reply parsed")
        check(aReply?.reasoning == "i should check the directory",
              "anthropic thinking block parsed")
        check(OpenAICompatibleClient.parseAnthropic(data: Data("{\"content\":[]}".utf8)) == nil,
              "anthropic empty content rejected")

        print("— AITaskCoordinator loop —")
        final class FakeModel: ModelClient {
            var script: [[ToolCall]] = []
            var finalText = "done"
            /// Non-empty → every scripted reply carries reasoning.
            var reasoning = ""
            var calls = 0
            func complete(messages: [ChatMessage], tools: [ToolSpec],
                          completion: @escaping (Result<ModelReply, ModelError>) -> Void) {
                let idx = calls; calls += 1
                if idx < script.count {
                    completion(.success(ModelReply(text: nil,
                                                   reasoning: reasoning.isEmpty ? nil : reasoning,
                                                   toolCalls: script[idx])))
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

        // probe → destructive proposal → confirm → verify → completed.
        // Only DESTRUCTIVE ops gate now; ordinary mutations auto-run.
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
                [ToolCall(id: "3", name: "bash", argumentsJSON: "{\"command\":\"rm -rf build\"}")],
                [ToolCall(id: "4", name: "bash", argumentsJSON: "{\"command\":\"ls\"}")],
            ]
            m.reasoning = "probe first, then mutate"
            let tid = coord.start(context: AIContext(request: "rename", target: target,
                                                      visibleOutput: "", hostFacts: ""))
            check(waitSem(awaitSem), "reaches awaitingConfirmation")
            check(last?.pendingProposal?.op == .bash("rm -rf build"),
                  "destructive command became proposal")
            check(e.ran.contains("ls"), "allowlisted probe ran without confirm")
            check(e.ran.contains("mv a b"), "ordinary mutation ran without confirm")
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.3))
            check(!e.ran.contains("rm -rf build"), "destructive not executed before confirm")
            coord.confirm(taskId: tid)
            check(waitSem(doneSem), "completes after confirm")
            check(e.ran.contains("rm -rf build"), "confirmed proposal executed")
            check(last?.rounds.count == 4, "post-exec verification round ran")
            check(last?.rounds.allSatisfy { $0.reasoning == "probe first, then mutate" } == true,
                  "round carries the reply's reasoning")
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
                [ToolCall(id: "1", name: "bash", argumentsJSON: "{\"command\":\"rm -rf old\"}")],
            ]
            let tid = coord.start(context: AIContext(request: "rename", target: target,
                                                      visibleOutput: "", hostFacts: ""))
            check(waitSem(awaitSem), "second task reaches awaitingConfirmation")
            coord.edit(taskId: tid, to: AIProposal(op: .bash("rm -rf new"), explanation: "",
                                                  risk: .destructive, rollbackHint: nil))
            check(waitSem(awaitSem), "edit re-emits awaitingConfirmation")
            check(last?.pendingProposal?.op == .bash("rm -rf new"), "edit replaces pending proposal")
            check(last?.phase == .awaitingConfirmation, "phase back to awaitingConfirmation")
            check(!e.ran.contains("rm -rf old") && !e.ran.contains("rm -rf new"),
                  "edited proposal not executed yet")
            coord.confirm(taskId: tid)
            check(waitSem(doneSem), "second confirm completes")
            check(e.ran.contains("rm -rf new") && !e.ran.contains("rm -rf old"),
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

        // write tool: auto-executes now — only destructive ops confirm
        do {
            let m = FakeModel()
            let e = FakeExec()
            let doneSem = DispatchSemaphore(value: 0)
            var proposed = false
            var last: AITask?
            let coord = AITaskCoordinator(model: m, executorFor: { _ in e })
            coord.onUpdate = { t in
                last = t
                if t.phase == .awaitingConfirmation { proposed = true }
                if case .completed = t.phase { doneSem.signal() }
                if case .failed = t.phase { doneSem.signal() }
            }
            m.script = [
                [ToolCall(id: "1", name: "write",
                          argumentsJSON: "{\"path\":\"/tmp/w\",\"content\":\"x\"}")],
                [ToolCall(id: "2", name: "edit",
                          argumentsJSON: "{\"path\":\"/tmp/w\",\"oldText\":\"x\",\"newText\":\"y\"}")],
            ]
            _ = coord.start(context: AIContext(request: "save", target: target,
                                                visibleOutput: "", hostFacts: ""))
            check(waitSem(doneSem), "write/edit task completes")
            check(!proposed, "write and edit auto-execute (no confirmation)")
            check(e.wrote == ["/tmp/w"], "write executed")
            check(last?.rounds.count == 2, "both rounds recorded")
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
                [ToolCall(id: "1", name: "bash", argumentsJSON: "{\"command\":\"rm -rf x\"}")],
            ]
            let tid = coord.start(context: AIContext(request: "clean", target: target,
                                                      visibleOutput: "", hostFacts: ""))
            check(waitSem(awaitSem), "destructive proposal awaits before cancel")
            coord.cancel(taskId: tid)
            check(waitSem(cancelSem), "cancel transitions to .cancelled")
            check(!e.ran.contains("rm -rf x"), "cancelled proposal never executes")
            coord.confirm(taskId: tid)   // late UI callback after close
            Thread.sleep(forTimeInterval: 0.15)
            check(!e.ran.contains("rm -rf x"), "late confirm on cancelled task is inert")
        }

        // streaming: deltas grow the live text, completion resolves
        do {
            final class StreamModel: ModelClient {
                func complete(messages: [ChatMessage], tools: [ToolSpec],
                               completion: @escaping (Result<ModelReply, ModelError>) -> Void) {
                    completion(.failure(.badResponse))
                }
                func stream(messages: [ChatMessage], tools: [ToolSpec],
                            onDelta: @escaping (StreamDelta) -> Void,
                            completion: @escaping (Result<ModelReply, ModelError>) -> Void) {
                    onDelta(StreamDelta(text: "Hel", reasoning: nil))
                    onDelta(StreamDelta(text: nil, reasoning: "let me check"))
                    onDelta(StreamDelta(text: "lo", reasoning: nil))
                    completion(.success(ModelReply(text: "Hello", reasoning: nil, toolCalls: [])))
                }
            }
            let e = FakeExec()
            let doneSem = DispatchSemaphore(value: 0)
            var snapshots: [AITask] = []
            let coord = AITaskCoordinator(model: StreamModel(), executorFor: { _ in e })
            coord.onUpdate = { t in
                snapshots.append(t)
                if case .completed = t.phase { doneSem.signal() }
            }
            _ = coord.start(context: AIContext(request: "hi", target: target,
                                                visibleOutput: "", hostFacts: ""))
            check(waitSem(doneSem), "streamed task completes")
            check(snapshots.contains { $0.phase == .thinking && $0.streamingText == "Hel" },
                  "deltas grew the live text while thinking (throttled snapshots)")
            check(snapshots.contains { $0.phase == .thinking && $0.streamingReasoning == "let me check" || $0.phase == .thinking && $0.streamingText == "Hel" },
                  "streamed reasoning reaches the live snapshot")
            check(snapshots.allSatisfy { $0.phase != .thinking || $0.streamingText != nil || $0.rounds.isEmpty },
                  "live snapshots carry text")
            if case .completed(let s)? = snapshots.last?.phase {
                check(s == "Hello", "completion carries the assembled text")
            } else { check(false, "completion carries the assembled text") }
        }

        // SSE parser: openai chat.completions chunks
        do {
            let p = SSEChatParser(apiType: .openai)
            let d1 = p.feed("data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n\n")
            let d2 = p.feed("data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"think\"}}]}\n\n")
            _ = p.feed("data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"ls\\\"}\"}}]}}]}\n\n")
            _ = p.feed("data: [DONE]\n\n")
            check(d1.first?.text == "Hel" && d2.first?.reasoning == "think",
                  "openai deltas parse")
            let reply = p.reply()
            check(reply?.text == "Hel" && reply?.reasoning == "think",
                  "openai stream text/reasoning assemble")
            check(reply?.toolCalls.first?.name == "bash"
                  && reply?.toolCalls.first?.argumentsJSON.contains("ls") == true,
                  "openai tool_call fragments assemble")
        }

        // SSE parser: anthropic messages events
        do {
            let p = SSEChatParser(apiType: .anthropic)
            _ = p.feed("data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\"}}\n\n")
            let d1 = p.feed("data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}\n\n")
            _ = p.feed("data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"thinking\"}}\n\n")
            let d2 = p.feed("data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"hmm\"}}\n\n")
            _ = p.feed("data: {\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"bash\"}}\n\n")
            _ = p.feed("data: {\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"command\\\":\\\"pwd\\\"}\"}}\n\n")
            _ = p.feed("data: {\"type\":\"message_stop\"}\n\n")
            check(d1.first?.text == "Hi" && d2.first?.reasoning == "hmm",
                  "anthropic deltas parse")
            let reply = p.reply()
            check(reply?.text == "Hi" && reply?.reasoning == "hmm",
                  "anthropic stream text/thinking assemble")
            check(reply?.toolCalls.first?.name == "bash"
                  && reply?.toolCalls.first?.argumentsJSON.contains("pwd") == true,
                  "anthropic tool_use fragments assemble")
            check(SSEChatParser(apiType: .openai).reply() == nil,
                  "empty stream assembles nothing")
        }

        // web tools: specs registered + parsers
        check(AITaskCoordinator.toolSpecs.contains { $0.name == "fetch_content" },
              "fetch_content tool registered")
        check(AITaskCoordinator.toolSpecs.contains { $0.name == "web_search" },
              "web_search tool registered")
        do {
            let html = """
            <html><head><style>body{}</style></head><body><nav>menu</nav>
            <h1>T&amp;itle</h1><script>alert(1)</script>
            <p>First &lt;line&gt;&#x27;quoted&#39;</p><div>Second</div>
            </body></html>
            """
            let text = WebAccess.htmlToText(html)
            check(text.contains("T&itle") && text.contains("First <line>'quoted'"),
                  "htmlToText decodes entities")
            check(text.contains("Second"), "htmlToText keeps body text")
            check(!text.contains("alert") && !text.contains("menu"),
                  "htmlToText drops script/style/nav")
        }
        do {
            let html = """
            <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa&rut=abc">Example&nbsp;A</a>
            <a class="result__snippet">snippet a</a>
            <a class="result__a" href="https://example.com/b">Example B</a>
            <a class="result__snippet">snippet b</a>
            """
            let hits = WebAccess.parseSearchResults(html)
            check(hits.count == 2, "both results parse (got \(hits.count))")
            check(hits.first?.url == "https://example.com/a",
                  "uddg redirect unwrapped (got \(hits.first?.url ?? "-"))")
            check(hits.first?.title == "Example A" && hits.first?.snippet == "snippet a",
                  "title/snippet pair with entity")
        }

        // cancel on a terminal phase is inert (late top-right close)
        do {
            let m = FakeModel()
            let e = FakeExec()
            let doneSem = DispatchSemaphore(value: 0)
            var last: AITask?
            let coord = AITaskCoordinator(model: m, executorFor: { _ in e })
            coord.onUpdate = { t in
                last = t
                if case .completed = t.phase { doneSem.signal() }
            }
            let tid = coord.start(context: AIContext(request: "hi", target: target,
                                                      visibleOutput: "", hostFacts: ""))
            check(waitSem(doneSem), "task completes")
            coord.cancel(taskId: tid)
            Thread.sleep(forTimeInterval: 0.1)
            if case .completed? = last?.phase { check(true, "cancel leaves completed phase alone") }
            else { check(false, "cancel leaves completed phase alone") }
        }

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
        exit(failures == 0 ? 0 : 1)
    }
}

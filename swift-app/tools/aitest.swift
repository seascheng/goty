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

        exit(failures == 0 ? 0 : 1)
    }
}

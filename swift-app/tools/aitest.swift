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

        exit(failures == 0 ? 0 : 1)
    }
}

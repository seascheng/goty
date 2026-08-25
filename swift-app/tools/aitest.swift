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

        exit(failures == 0 ? 0 : 1)
    }
}

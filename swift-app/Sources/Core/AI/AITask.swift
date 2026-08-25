// goty — see CLAUDE.md for the working principles.
import Foundation

// MARK: - AITaskPhase

/// Task lifecycle. Probe rounds surface as `thinking`; the spec's
/// thinking⇄probing alternation is data (rounds), not phases.
enum AITaskPhase: Equatable {
    case idle
    case thinking
    case awaitingConfirmation
    case budgetExhausted(progress: String)
    case executing
    case completed(summary: String)
    case failed(String)
    case cancelled
}

// MARK: - AIRound

/// One ReAct round: what the model called and what came back.
struct AIRound {
    var reasoning: String?
    var toolName: String?
    var toolInput: String
    var toolResult: String
}

// MARK: - AITask

/// Bounded unit of work: context + phase + rounds + pending proposal +
/// the round budget (25 per task, +25 on explicit continue — never a
/// silent reset).
struct AITask {
    let id: UUID
    let context: AIContext
    private(set) var phase: AITaskPhase
    private(set) var rounds: [AIRound]
    private(set) var pendingProposal: AIProposal?
    private(set) var budgetRemaining: Int

    init(id: UUID = UUID(), context: AIContext, budget: Int = 25) {
        self.id = id
        self.context = context
        self.phase = .idle
        self.rounds = []
        self.pendingProposal = nil
        self.budgetRemaining = budget
    }

    mutating func advance(to newPhase: AITaskPhase) {
        phase = newPhase
    }

    mutating func append(round: AIRound) {
        rounds.append(round)
    }

    /// Decrements the budget; false (and no decrement) at zero.
    mutating func spendRound() -> Bool {
        guard budgetRemaining > 0 else { return false }
        budgetRemaining -= 1
        return true
    }

    mutating func setPending(_ proposal: AIProposal?) {
        pendingProposal = proposal
    }
}

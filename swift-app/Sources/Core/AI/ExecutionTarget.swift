// goty — see CLAUDE.md for the working principles.
import Foundation

// MARK: - ExecutionTarget

/// Where an AI task runs: the pane's workspace/pane identity plus the
/// transport (local or ssh). Transparency over the target is the spec's
/// core promise — the card always shows what host an op will touch.
struct ExecutionTarget: Equatable {
    enum Transport: Equatable {
        case local
        case ssh(host: String)
    }
    var workspaceId: UUID
    var paneId: String
    var displayName: String
    var transport: Transport
    var cwd: String?
    var shell: String?
}

// MARK: - AIContext

/// Everything the model sees at task start: the user request, the target,
/// the pane's visible output tail, and probed host facts.
struct AIContext {
    var request: String
    var target: ExecutionTarget
    var visibleOutput: String
    var hostFacts: String
}

// MARK: - CommandRisk

/// Risk classification the executor-side policy assigns; the model never
/// decides its own permissions.
enum CommandRisk: Equatable {
    case readOnly
    case mutating
    case destructive
}

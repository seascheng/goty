// goty — see CLAUDE.md for the working principles.
import Foundation

// MARK: - AIProposal

/// A mutation the model proposed. Never executed until the user confirms
/// the exact fingerprint.
struct AIProposal: Equatable {
    enum Op: Equatable {
        case bash(String)
        case write(path: String, content: String)
        case edit(path: String, oldText: String, newText: String)
    }
    var op: Op
    var explanation: String
    var risk: CommandRisk
    var rollbackHint: String?

    /// Confirmation binds to op case name + all associated values
    /// (newline-joined); the explanation is deliberately excluded.
    var fingerprint: String {
        switch op {
        case .bash(let command):
            return ["bash", command].joined(separator: "\n")
        case .write(let path, let content):
            return ["write", path, content].joined(separator: "\n")
        case .edit(let path, let oldText, let newText):
            return ["edit", path, oldText, newText].joined(separator: "\n")
        }
    }
}

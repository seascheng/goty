// goty — see CLAUDE.md for the working principles.
import Foundation

/// Spawn shape every adapter shares: the process to run in the sessiond
/// pane and the ring budget for reattach replay. Dialect-agnostic —
/// whether the child speaks ACP, stream-json, app-server, or pi rpc is
/// the session implementation's business, not the spawner's.
struct AgentSpawn {
    let command: String
    let args: [String]
    let ringBytes: UInt64
}

/// Everything an AgentSessioning implementation needs at construction.
struct AgentPaneParams {
    let paneId: String
    let cwd: String?
    let environment: [String: String]
    let daemon: SessionDaemon
}

/// One agent family as the app offers it: fixed UI (AgentSessioning +
/// AgentSessionEvent) over a per-family wire dialect.
struct AgentDescriptor {
    let key: String
    let label: String
    /// Binary availability probing looks for (never spawned).
    let binary: String
    let spawn: AgentSpawn
    let make: (AgentPaneParams) -> AgentSessioning

    /// PATH search for an executable — no subprocess. The interactive
    /// env capture is the whole reason this works from a Finder launch.
    func isAvailable(path: String) -> Bool {
        for dir in path.split(separator: ":") where !dir.isEmpty {
            let candidate = URL(fileURLWithPath: String(dir))
                .appendingPathComponent(binary).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return true
            }
        }
        return false
    }
}

/// The agent catalog. Menus, `@agent` triggers, pane restore and the
/// spawn path all read this table — adding an agent family is one entry
/// plus its session implementation, nothing else.
enum AgentRegistry {
    static let descriptors: [AgentDescriptor] = [
        AgentDescriptor(
            key: "omp",
            label: "omp (GUI)",
            binary: "omp",
            spawn: AgentSpawn(command: "omp", args: ["acp"], ringBytes: 67_108_864),
            make: { params in
                AgentSession(paneId: params.paneId, cwd: params.cwd,
                             grid: AgentSession.fixedGrid,
                             environment: params.environment,
                             spawn: ompSpawn, daemon: params.daemon)
            }),
        AgentDescriptor(
            key: "claude",
            label: "Claude Code",
            binary: "claude",
            spawn: AgentSpawn(command: "claude",
                              args: ["--print", "--input-format", "stream-json",
                                     "--output-format", "stream-json", "--verbose"],
                              ringBytes: 16_777_216),
            make: { params in ClaudeSession(params: params) }),
        // codex / pi land with their adapters (plan tasks 4-5).
    ]

    /// The omp spawn shape shared by the descriptor table above and
    /// tests that construct AgentSession directly.
    static let ompSpawn = AgentSpawn(command: "omp", args: ["acp"], ringBytes: 67_108_864)

    static func descriptor(for key: String) -> AgentDescriptor? {
        descriptors.first { $0.key == key }
    }

    /// Menu/picker entries in display order, flagged for availability.
    /// Unavailable entries stay visible (disabled + tooltip) — a missing
    /// CLI is a fixable condition, not a reason to hide the agent.
    static func pickerEntries(path: String) -> [(key: String, label: String,
                                                  available: Bool)] {
        descriptors.map { ($0.key, $0.label, $0.isAvailable(path: path)) }
    }
}

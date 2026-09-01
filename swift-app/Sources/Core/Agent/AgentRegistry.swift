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
    /// Session the pane had loaded when it was last open (state.json).
    /// The adapter re-loads it on connect; nil = start fresh / newest.
    var restoredSessionId: String? = nil
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
            label: "OMP",
            binary: "omp",
            spawn: AgentSpawn(command: "omp", args: ["--mode", "rpc"],
                              ringBytes: 67_108_864),
            make: { params in OmpSession(params: params) }),
        AgentDescriptor(
            key: "claude",
            label: "Claude Code",
            binary: "claude",
            spawn: AgentSpawn(command: "claude",
                              args: ["--print", "--input-format", "stream-json",
                                     "--output-format", "stream-json", "--verbose"],
                              ringBytes: 16_777_216),
            make: { params in ClaudeSession(params: params) }),
        AgentDescriptor(
            key: "codex",
            label: "Codex",
            binary: "codex",
            spawn: AgentSpawn(command: "codex", args: ["app-server"],
                              ringBytes: 16_777_216),
            make: { params in CodexSession(params: params) }),
        AgentDescriptor(
            key: "pi",
            label: "pi",
            binary: "pi",
            spawn: AgentSpawn(command: "pi", args: ["--mode", "rpc"],
                              ringBytes: 16_777_216),
            make: { params in PiLegacySession(params: params) }),
    ]

    /// The omp spawn shape tests construct OmpSession panes with.
    static let ompSpawn = AgentSpawn(command: "omp", args: ["--mode", "rpc"],
                                     ringBytes: 67_108_864)

    static func descriptor(for key: String) -> AgentDescriptor? {
        descriptors.first { $0.key == key }
    }

    /// Menu/picker entries in display order; the caller injects the
    /// FOCUSED workspace's availability (local user PATH vs a remote
    /// link's connect-time probe). Unavailable agents are DROPPED
    /// (2026-08-31): a picker offers only what will actually open —
    /// keyboard and @agent triggers still hit the openAgentSession gate.
    static func pickerEntries(isAvailable: (String) -> Bool)
        -> [(key: String, label: String, available: Bool)] {
        descriptors.map { ($0.key, $0.label, isAvailable($0.key)) }
    }
}

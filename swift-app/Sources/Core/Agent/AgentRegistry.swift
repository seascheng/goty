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
    let binary: String
    /// The session-store listing key the daemon serves for this family
    /// ("omp"/"claude"/"pi"; nil = no daemon-side listing — codex).
    let storeListKey: String?
    let spawn: AgentSpawn
    /// Factory is main-actor: adapters are main-actor confined from
    /// construction (their state is the UI's state).
    let make: @MainActor (AgentPaneParams) -> any AgentSessioning
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
    /// Keys in catalog order, usable from nonisolated contexts (line
    /// triggers match @agent prefixes on byte streams). Kept in lockstep
    /// with `descriptors` — agenttest asserts the two agree.
    nonisolated static let agentKeys: [String] = ["omp", "claude", "codex", "pi"]

    @MainActor
    static let descriptors: [AgentDescriptor] = [
        AgentDescriptor(
            key: "omp",
            label: "OMP",
            binary: "omp",
            storeListKey: "omp",
            // NOTE: ringBytes here is descriptive metadata only — the
            // live value every pi-mono pane spawns with lives in
            // PiSession.openPane (1MB, see the comment there).
            //
            // rpc-ui = rpc + the extension-UI channel: omp registers the
            // ask tool (hasUI) and surfaces approvals/questions as
            // extension_ui_request frames we already bridge. Plain rpc
            // leaves ask unregistered — brainstorm questions degrade to
            // plain text A/B lists.
            spawn: AgentSpawn(command: "omp", args: ["--mode", "rpc-ui"],
                              ringBytes: 1_048_576),
            make: { @MainActor params in OmpSession(params: params) }),
        AgentDescriptor(
            key: "claude",
            label: "Claude Code",
            binary: "claude",
            storeListKey: "claude",
            spawn: AgentSpawn(command: "claude",
                              args: ["--print", "--input-format", "stream-json",
                                     "--output-format", "stream-json", "--verbose"],
                              ringBytes: 16_777_216),
            make: { @MainActor params in ClaudeSession(params: params) }),
        AgentDescriptor(
            key: "codex",
            label: "Codex",
            binary: "codex",
            storeListKey: nil,
            spawn: AgentSpawn(command: "codex", args: ["app-server"],
                              ringBytes: 16_777_216),
            make: { @MainActor params in CodexSession(params: params) }),
        AgentDescriptor(
            key: "pi",
            label: "pi",
            binary: "pi",
            storeListKey: "pi",
            // Descriptive only — see PiSession.openPane for the live
            // ring size (1MB, both dialects).
            spawn: AgentSpawn(command: "pi", args: ["--mode", "rpc"],
                              ringBytes: 1_048_576),
            make: { @MainActor params in PiLegacySession(params: params) }),
    ]

    /// The omp spawn shape tests construct OmpSession panes with
    /// (rpc-ui: the extension-UI channel the ask tool needs).
    static let ompSpawn = AgentSpawn(command: "omp", args: ["--mode", "rpc-ui"],
                                     ringBytes: 67_108_864)

    @MainActor
    static func descriptor(for key: String) -> AgentDescriptor? {
        descriptors.first { $0.key == key }
    }
    /// Menu/picker entries in display order; the caller injects the
    /// FOCUSED workspace's availability (local user PATH vs a remote
    /// link's connect-time probe). Unavailable agents are DROPPED
    /// (2026-08-31): a picker offers only what will actually open —
    @MainActor
    static func pickerEntries(isAvailable: (String) -> Bool)
        -> [(key: String, label: String, available: Bool)] {
        descriptors.map { ($0.key, $0.label, isAvailable($0.key)) }
    }

    /// Availability probing needs only (key, binary) pairs, and it runs
    /// on background capture queues — this nonisolated projection keeps
    /// the actor-confined factory out of those closures. agenttest
    /// asserts it stays in lockstep with `descriptors`.
    nonisolated static let probeCatalog: [(key: String, binary: String)] = [
        ("omp", "omp"), ("claude", "claude"), ("codex", "codex"), ("pi", "pi"),
    ]

    /// Store-listing key by agent key, nonisolated for background
    /// title prefetches. Missing key = no daemon-side listing (codex).
    nonisolated static let storeListKeys: [String: String] = [
        "omp": "omp", "claude": "claude", "pi": "pi",
    ]
}

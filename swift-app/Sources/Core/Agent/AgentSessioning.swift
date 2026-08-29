// goty — see CLAUDE.md for the working principles.
import Foundation

/// What a GUI agent pane needs from ANY agent implementation. The UI
/// speaks this interface; each agent family adapts its wire dialect
/// behind it (Adapters/: OmpSession speaks ACP, Claude/Codex/Pi their
/// own). Events (`AgentSessionEvent`) are the dialect-neutral currency
/// crossing this seam.
protocol AgentSessioning: AnyObject {
    var delegate: AgentSessionDelegate? { get set }
    var sessionId: String? { get }
    var isWorking: Bool { get }
    var configOptions: [AgentConfigOption] { get }
    var commands: [AgentSlashCommand] { get }
    /// Working directory — file index and session-store filters.
    var cwd: String? { get }
    /// The session a reconnect would restore via `load` after a fresh
    /// spawn (the pane died with the daemon). Defaults to `sessionId`.
    var lastSessionId: String? { get }

    func connect(completion: ((Bool) -> Void)?)
    func send(_ text: String)
    func cancel()
    func respondPermission(requestID: String, optionId: String)
    func setConfigOption(id: String, value: String)
    /// Persisted-session directory (session/list) filtered to the pane cwd.
    func listSessions(completion: @escaping ([AgentSessionSummary]) -> Void)
    /// Resume a persisted agent session on this connection; replayed
    /// history arrives as normal session/update events.
    func load(sessionId: String, completion: ((Bool) -> Void)?)
    /// Drop the transport and re-open it (attach-or-spawn). Attach keeps
    /// a live pane running mid-turn — the ring replay rebuilds the page.
    /// A fresh spawn (the daemon lost the pane) re-handshakes, and the
    /// caller restores context via `load(lastSessionId)`.
    func reconnect(completion: ((Bool) -> Void)?)
    func shutdown()
}

extension AgentSessioning {
    var lastSessionId: String? { sessionId }
    /// Ring-replay diagnostics — omp is the only adapter with a ring to
    /// measure; others report zeros.
    var debugReplayBytes: Int { 0 }
    var debugReplayFrames: Int { 0 }
}
/// The dialect-neutral turn lifecycle, derived ONCE in AgentPaneHost from
/// AgentSessionEvents (paseo's lastStatus model, minus its persistence —
/// the daemon's pane + the agent's own session store are the authority).
/// `thinking` vs `executing` is best-effort: message/thought deltas mean
/// thinking, an in-flight tool call means executing — an agent that does
/// both at once shows executing.
enum AgentTurnState: Equatable {
    case starting
    case idle
    case thinking
    case executing
    case awaitingPermission
    /// Process exited, handshake timed out, connect failed — with the
    /// human-readable reason the composer shows next to 重试.
    case errored(String)

    var isActive: Bool {
        self == .thinking || self == .executing || self == .awaitingPermission
    }
}

/// Dialect-neutral: the delegate never learns which adapter runs.
protocol AgentSessionDelegate: AnyObject {
    func session(_ session: AgentSessioning, didEmit events: [AgentSessionEvent])
    func sessionDidFail(_ session: AgentSessioning, reason: String)
    /// The pane transport dropped while the process may still be alive
    /// (daemon restart, ssh forward loss) — distinct from sessionDidFail's
    /// terminal failures: the host answers with a reconnect loop, not a
    /// dead pane. Adapters that cannot reconnect never call it.
    func session(_ session: AgentSessioning, didDisconnectBecause reason: String)
}

extension AgentSessionDelegate {
    func session(_ session: AgentSessioning, didDisconnectBecause reason: String) {}
}

/// Agent panes are line-agnostic; the grid only exists because the
/// daemon sizes every PTY. Fixed sane defaults; resize is never sent.
enum AgentPaneDefaults {
    static let grid = SessionGrid(columns: 120, rows: 40, cellWidth: 8, cellHeight: 16)
}

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
    func shutdown()
}

extension AgentSessioning {
    /// Ring-replay diagnostics — omp is the only adapter with a ring to
    /// measure; others report zeros.
    var debugReplayBytes: Int { 0 }
    var debugReplayFrames: Int { 0 }
}

/// Agent panes are line-agnostic; the grid only exists because the
/// daemon sizes every PTY. Fixed sane defaults; resize is never sent.
enum AgentPaneDefaults {
    static let grid = SessionGrid(columns: 120, rows: 40, cellWidth: 8, cellHeight: 16)
}

/// Dialect-neutral: the delegate never learns which adapter runs.
protocol AgentSessionDelegate: AnyObject {
    func session(_ session: AgentSessioning, didEmit events: [AgentSessionEvent])
    func sessionDidFail(_ session: AgentSessioning, reason: String)
}

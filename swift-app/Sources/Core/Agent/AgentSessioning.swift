// goty — see CLAUDE.md for the working principles.
import Foundation

/// What a GUI agent pane needs from ANY agent implementation. The UI
/// speaks this interface; each agent family adapts its wire dialect
/// behind it (Adapters/: Claude/Codex their own, Pi+omp share the
/// pi-mono rpc runtime in PiSession). Events (`AgentSessionEvent`)
/// are the dialect-neutral currency crossing this seam.
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
    /// true = the adapter consumes `restoredSessionId` itself inside
    /// connect (claude: store replay + --resume respawn) and the caller
    /// must NOT also load() after connect.
    var selfManagesRestore: Bool { get }
    /// Ring-replay diagnostics; zero where no ring exists.
    var debugReplayBytes: Int { get }
    var debugReplayFrames: Int { get }

    func connect(completion: ((Bool) -> Void)?)
    func send(_ text: String, images: [AgentImage])
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

    // MARK: capabilities (P1–P3). REQUIREMENTS, not extension methods:
    // calling an extension-only method through `any AgentSessioning`
    // statically binds to the extension default and silently bypasses
    // the adapter's implementation (the 2026-08-31 vanishing-steer bug).
    /// Mid-turn steering: `steer` interrupts the current run with the
    /// message. Follow-ups are NOT an adapter concern — the pane owns
    /// the outbox queue and re-sends through send() at turn settle.
    func steer(_ text: String, images: [AgentImage])
    /// Fast-mode toggle (omp set_fast_mode).
    func setFastMode(enabled: Bool)
    /// OAuth login surface; empty completion = unsupported.
    func loginProviders(completion: @escaping ([[String: Any]]) -> Void)
    func startLogin(providerId: String)
    /// Export the conversation; the string is the written file path.
    func exportHTML(completion: @escaping (String?) -> Void)
    /// Session stats payload for the stats dialog.
    func sessionStats(completion: @escaping ([String: Any]?) -> Void)
    /// Branch from a session entry into a new session file.
    func branch(entryId: String, completion: @escaping (Bool) -> Void)
    /// Worktree fork WITHOUT disturbing this session's live process:
    /// a throwaway adapter resumes the source file, forks at the entry
    /// and reports the NEW session id (nil = failed/unsupported). Safe
    /// to call while this session's turn is running.
    func forkToNewSession(entryId: String, completion: @escaping (String?) -> Void)
    /// Host-owned tools the agent may call back into; registered on
    /// the next handshake.
    func setHostTools(_ tools: AgentHostTools)
    /// Host identity for GUI-side actions: does this agent's process
    /// run on THIS Mac (paths it reports are local files the GUI can
    /// reveal/open), or on a remote host (its paths live on that
    /// machine; GUI-side file actions must say so instead of probing
    /// the local filesystem)? Transport-level fact — adapters answer
    var runsOnThisMac: Bool { get }
    /// Older history for the tail-first prepend pipeline; nil = the
    /// adapter loaded (or holds no) older entries. Called when the
    /// page's history sentinel reaches the top of what it has.
    func loadOlderHistory(completion: @escaping ([AgentSessionEvent]?) -> Void)

}


extension AgentSessioning {
    /// Local by default: adapters without a daemon relationship run on
    /// the GUI's own machine.
    var runsOnThisMac: Bool { true }
    /// No older history by default: only tail-first dialects page in.
    func loadOlderHistory(completion: @escaping ([AgentSessionEvent]?) -> Void) {
        completion(nil)
    }
    var lastSessionId: String? { sessionId }
    /// true = the adapter consumes `restoredSessionId` itself inside
    /// connect (claude: store replay + --resume respawn) and the caller
    /// must NOT also load() after connect.
    var selfManagesRestore: Bool { false }
    /// Mid-turn steering (RPC steer): `steer` interrupts the current run
    /// with the message. Unsupported adapters no-op.
    func steer(_ text: String, images: [AgentImage]) {}
    /// Single-argument conveniences: extension bodies forward into the
    /// requirements above, so calls through `any AgentSessioning`
    /// still dispatch dynamically to the adapter's implementation.
    func send(_ text: String) { send(text, images: []) }
    func steer(_ text: String) { steer(text, images: []) }
    /// Fast-mode toggle (omp set_fast_mode). Unsupported adapters no-op.
    func setFastMode(enabled: Bool) {}
    /// OAuth login surface (omp get_login_providers/login); empty = none.
    func loginProviders(completion: @escaping ([[String: Any]]) -> Void) {
        completion([])
    }
    func startLogin(providerId: String) {}
    /// Export the conversation (omp export_html); the returned string is
    /// the written file path, nil = unsupported/failed.
    func exportHTML(completion: @escaping (String?) -> Void) { completion(nil) }
    /// Session stats (omp get_session_stats) for the stats dialog.
    func sessionStats(completion: @escaping ([String: Any]?) -> Void) { completion(nil) }
    /// Worktree fork: unsupported outside omp (nil).
    func forkToNewSession(entryId: String, completion: @escaping (String?) -> Void) {
        completion(nil)
    }
    func branch(entryId: String, completion: @escaping (Bool) -> Void) { completion(false) }
    /// Host-owned tools the agent may call back into (omp set_host_tools).
    /// Registered on the next handshake after this call.
    func setHostTools(_ tools: AgentHostTools) {}
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

/// Host-owned tools the agent may call back into over RPC
/// (`set_host_tools` / `host_tool_call`). The UI layer supplies the
/// closures — Core stays AppKit-free. `run` returns the
/// host_tool_result payload: {"content":[{type:text,text:…}]}.
final class AgentHostTools {
    struct Tool {
        let name: String
        let label: String
        let description: String
        /// JSON-Schema object for the tool parameters.
        let parameters: [String: Any]
        let run: ([String: Any]) -> [String: Any]
    }

    let tools: [Tool]

    init(tools: [Tool]) {
        self.tools = tools
    }
}

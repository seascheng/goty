// goty — see CLAUDE.md for the working principles.
import Foundation

// MARK: - Model

/// One terminal pane. Every pane is a native ghostty EXEC surface (the
/// surface owns its PTY, so resize, scrollback, wrap and redraw are all
/// native ghostty — a single source of screen state).
/// Identity of one pane surface: its workspace + the persisted pane id.
/// Replaces the "uuid:paneId" packed string that leaked across the
/// coordinator/UI seam via hasPrefix matching.
struct HostKey: Hashable {
    let workspace: UUID
    let pane: String
}

extension HostKey {
    /// Stable pane identity on any sessiond: workspace UUID + pane UUID.
    /// Persisted pane ids from the tmux era (`%0`, `%1`) were only unique
    /// inside one workspace; the daemon registry is host-global, so the
    /// UUIDs keep the result stable across GUI restarts.
    var runtimeId: String { "\(workspace.uuidString)_\(pane)" }
}

enum PaneKind: Codable, Equatable {
    case terminal
    /// A GUI agent session; payload = the AgentCatalog key ("omp").
    case agent(String)
}

struct PaneState: Codable {
    let id: String        // pane UUID (stable, persisted)
    var cwd: String?
    /// Grid-cell geometry (normalized at layout time).
    var left: Int = 0
    var top: Int = 0
    var width: Int = 1
    var height: Int = 1
    /// Terminal pane vs GUI agent session. Absent in older state.json —
    /// decodes as .terminal so no migration is ever needed.
    var kind: PaneKind = .terminal
    /// Agent pane: the session the user last had loaded here (history
    /// pick or new turn). Persisted so reopening the app re-loads the
    /// SAME conversation instead of a blank pane. Absent in older
    /// state.json — decodes as nil.
    var agentSessionId: String?
    /// Agent pane: texts queued behind a running turn when the app last
    /// ran. omp only reports a COUNT, so the dock's queued list would be
    /// lost across a restart without this. Absent in older state.json —
    /// decodes as nil.
    var agentQueuedOutbox: [String]?

    init(id: String, cwd: String?, kind: PaneKind = .terminal,
         left: Int = 0, top: Int = 0, width: Int = 1, height: Int = 1) {
        self.id = id
        self.cwd = cwd
        self.kind = kind
        self.left = left
        self.top = top
        self.width = width
        self.height = height
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        left = try container.decodeIfPresent(Int.self, forKey: .left) ?? 0
        top = try container.decodeIfPresent(Int.self, forKey: .top) ?? 0
        width = try container.decodeIfPresent(Int.self, forKey: .width) ?? 1
        height = try container.decodeIfPresent(Int.self, forKey: .height) ?? 1
        kind = try container.decodeIfPresent(PaneKind.self, forKey: .kind) ?? .terminal
        agentSessionId = try container.decodeIfPresent(String.self, forKey: .agentSessionId)
    }
}

struct TabState: Codable {
    let id: String
    var name: String
    /// User-set title, ghostty's rule: nil = the surface's own title
    /// (OSC 0/2 through the PTY) drives display; non-nil always wins.
    /// Empty commit clears it (back to the program title). Persisted;
    /// older state.json without the key decodes as nil. Local and
    /// remote panes both flow through the one title channel.
    var userTitle: String? = nil
    /// Live agent-session title (omp's auto-generated name, or the
    /// loaded history entry's name). Display sits BETWEEN userTitle and
    /// the agent label: automatic naming must follow the session, but a
    /// manual rename always outranks it. Persisted like userTitle;
    /// absent keys in older state.json decode as nil.
    var agentTitle: String? = nil
    var panes: [PaneState]
    /// Command the space was spawned with (nil = plain shell) — drives the
    /// agent badge: an agent space shows its brand while it runs.
    var paneCommand: String?
    /// User color tag (hex). GUI-only; persisted in state.json so a
    /// structure rebuild never drops it.
    var color: String?
    /// User icon tag (SF Symbol name); nil = default terminal glyph.
    var icon: String?
}

struct WorkspaceState: Codable {
    let id: UUID
    var name: String
    var tabs: [TabState]
    var focusedTabIndex: Int
    /// Remote workspaces run on a goty-sessiond installed over ssh on
    /// this host (config alias); nil = the local sessiond. Persisted, so
    /// a restart restores the workspace list and re-attaches each remote.
    var sshHost: String?
    /// The right-panel side terminal's panes — zero or more per server,
    /// created lazily on the first Terminal-tab open (spec 2026-08-30;
    /// split-capable since the 2026-08-31 revision). Same cell geometry
    /// as tab panes; standard sessiond panes (attach, replay, reconnect
    /// like any other) that belong to NO TabState, so nothing that walks
    /// tabs sees them. Empty = never opened.
    var auxTerminalPanes: [PaneState] = []

    var focusedTab: TabState? {
        tabs.indices.contains(focusedTabIndex) ? tabs[focusedTabIndex] : nil
    }

    var isRemote: Bool { sshHost != nil }

    /// Display name: the host alias for servers, "Local" for this Mac —
    /// derived, never stored, so no state migration can ever be needed.
    var displayName: String { isRemote ? name : "Local" }
}

extension WorkspaceState {
    /// v1 stored ONE pane id (`auxTerminalPaneId`); the split-capable
    /// revision stores the pane array. The legacy id migrates into one
    /// full-rect pane at decode — in the initializer (not the store's
    /// migration pass) so every decode path, parked workspaces included,
    /// lands migrated.
    private enum LegacyKeys: String, CodingKey {
        case auxTerminalPaneId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        tabs = try c.decode([TabState].self, forKey: .tabs)
        focusedTabIndex = try c.decode(Int.self, forKey: .focusedTabIndex)
        sshHost = try c.decodeIfPresent(String.self, forKey: .sshHost)
        if let panes = try c.decodeIfPresent([PaneState].self, forKey: .auxTerminalPanes) {
            auxTerminalPanes = panes
        } else if let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            .decodeIfPresent(String.self, forKey: .auxTerminalPaneId) {
            auxTerminalPanes = [PaneState(id: legacy, cwd: nil)]
        } else {
            auxTerminalPanes = []
        }
    }
}

// MARK: - Space grouping (tty7 sidebar model)

/// One grouped block under the Spaces header. `name == nil` is the flat
/// list — tty7 renders a single headerless section when no tab has
/// reported a cwd yet.
struct SpaceSection {
    let name: String?
    let tabIndexs: [Int]
}

enum SpaceGrouping {
    /// tty7 `sidebar_sections`, space-keyed: one git REPO is one space
    /// — `spaceRoot` resolves every cwd inside it (subdirs, linked
    /// worktrees) to the repo's main worktree root; a non-repo cwd is
    /// its own space (nil → raw path until a fetch lands). Tabs without
    /// a cwd trail in a scratch section. All-unknown cwds collapse to
    /// one headerless section.
    static func sections(for tabs: [TabState],
                         spaceRoot: ((String) -> String?)? = nil,
                         scratchTitle: String = "Scratch") -> [SpaceSection] {
        let keys: [String?] = tabs.map { tab in
            tab.panes.first?.cwd.map { spaceRoot?($0) ?? $0 }
        }
        var order: [String] = []
        for case let key? in keys where !order.contains(key) { order.append(key) }
        if order.isEmpty {
            return [SpaceSection(name: nil, tabIndexs: Array(tabs.indices))]
        }
        let names = tailNames(for: order)
        var sections = zip(order, names).map { root, name in
            SpaceSection(name: name, tabIndexs: tabs.indices.filter { keys[$0] == root })
        }
        let scratch = tabs.indices.filter { keys[$0] == nil }
        if !scratch.isEmpty {
            sections.append(SpaceSection(name: scratchTitle, tabIndexs: scratch))
        }
        return sections
    }

    /// tty7 `group_names`: the shortest path tail that stays unique —
    /// "goty", growing to "ai_project/goty" only on collision.
    static func tailNames(for roots: [String]) -> [String] {
        let comps: [[String]] = roots.map { $0.split(separator: "/").map(String.init) }
        var depth = [Int](repeating: 1, count: roots.count)
        while true {
            let names: [String] = comps.enumerated().map { i, c in
                c.isEmpty ? roots[i] : c.suffix(depth[i]).joined(separator: "/")
            }
            var grew = false
            for i in names.indices where depth[i] < comps[i].count {
                let collides = names.enumerated().contains { j, name in j != i && name == names[i] }
                if collides {
                    depth[i] += 1
                    grew = true
                }
            }
            if !grew { return names }
        }
    }
}



/// The workspace store. Owns the tab/pane structure and persists it to
/// state.json so a fresh launch restores the layout.
final class WorkspaceStore {
    var workspaces: [WorkspaceState]
    var focusedIndex: Int = 0
    /// Remote servers removed WITHOUT closing their sessions: the whole
    /// state is parked here (same workspace/pane ids) so re-adding the
    /// host reattaches the panes still running on its daemon.
    var parked: [WorkspaceState] = []
    private let fileURL: URL

    var focused: WorkspaceState? {
        workspaces.indices.contains(focusedIndex) ? workspaces[focusedIndex] : nil
    }

    init(sessionName: String, fileURL override: URL? = nil) {
        let dir = NSHomeDirectory() + "/Library/Application Support/goty"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        fileURL = override ?? URL(fileURLWithPath: dir + "/state.json")
        var loaded: ([WorkspaceState], Int)? = nil
        var loadedParked: [WorkspaceState] = []
        if let data = try? Data(contentsOf: fileURL) {
            struct Envelope: Codable {
                let focusedIndex: Int
                let workspaces: [WorkspaceState]
                let parked: [WorkspaceState]?
            }
            if let env = try? JSONDecoder().decode(Envelope.self, from: data) {
                loaded = (env.workspaces, env.focusedIndex)
                loadedParked = env.parked ?? []
            } else if let legacy = try? JSONDecoder().decode([WorkspaceState].self, from: data) {
                loaded = (legacy, 0)
            } else {
                // Undecodable state must never be silently replaced: the
                // first save() would destroy the user's whole layout.
                // Park the file next to the live one and start fresh.
                let stamp = Int(Date().timeIntervalSince1970)
                let parked = fileURL.deletingLastPathComponent()
                    .appendingPathComponent("state.corrupt-\(stamp).json")
                try? FileManager.default.moveItem(at: fileURL, to: parked)
                NSLog("WorkspaceStore: undecodable state.json parked at %@",
                      parked.lastPathComponent)
            }
        }
        let savedIdx = loaded?.1 ?? 0
        if var (saved, _) = loaded, !saved.isEmpty {
            // Migration defense: older builds persisted empty pane ids, which
            // silently dropped the pane from every layout pass.
            for wi in saved.indices {
                for ti in saved[wi].tabs.indices {
                    saved[wi].tabs[ti].panes = saved[wi].tabs[ti].panes.map { pane in
                        pane.id.isEmpty
                            ? PaneState(id: UUID().uuidString, cwd: pane.cwd)
                            : pane
                    }
                }
                saved[wi].tabs.removeAll { $0.panes.isEmpty }
                if saved[wi].tabs.isEmpty && saved[wi].sshHost == nil {
                    let pane = PaneState(id: UUID().uuidString, cwd: nil)
                    saved[wi].tabs.append(TabState(id: UUID().uuidString, name: "1", panes: [pane]))
                    saved[wi].focusedTabIndex = 0
                }
                if !saved[wi].tabs.indices.contains(saved[wi].focusedTabIndex) {
                    saved[wi].focusedTabIndex = 0
                }
            }
            workspaces = saved
            focusedIndex = workspaces.indices.contains(savedIdx) ? savedIdx : 0
        } else {
            let pane = PaneState(id: UUID().uuidString, cwd: nil)
            let tab = TabState(id: UUID().uuidString, name: "1", panes: [pane])
            workspaces = [WorkspaceState(id: UUID(), name: sessionName, tabs: [tab], focusedTabIndex: 0)]
        }
        parked = loadedParked
    }

    func save() {
        struct Envelope: Codable {
            let focusedIndex: Int
            let workspaces: [WorkspaceState]
            let parked: [WorkspaceState]
        }
        if let data = try? JSONEncoder().encode(
            Envelope(focusedIndex: focusedIndex, workspaces: workspaces,
                     parked: parked)) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

}

// MARK: - User shell environment

/// The user's REAL shell environment, captured once. A GUI launched from
/// Finder/launchd inherits a minimal environment — and the user's
/// toolchain (homebrew, version managers) lives in `.zshrc`, which a
/// NON-interactive `zsh -l -c` never sources. The old capture therefore
/// returned the inherited ~20 vars on Finder launches and spawned agent
/// CLIs with a PATH that could not find them: `omp: not found`, the pane
/// process died instantly, and everything downstream (connect, history,
/// resume) silently broke. Dev launches from a full shell masked this
/// for the entire M1 development period.
///
/// Two countermeasures, both required:
/// - capture INTERACTIVELY (`-l -i`): sources `.zshrc`, where the real
///   PATH is set up;
/// - capture from a CLEAN parent environment: what the GUI happens to
///   inherit must not leak into (or be mistaken for) the user's setup.
/// The result overrides the process environment per key, so basics like
/// TMPDIR survive even when the capture comes up short.
enum UserShellEnv {
    /// Bounded child runner for the capture: stdin MUST be the null
    /// device (an inherited TTY makes an interactive zsh wait on the
    /// terminal forever — the launch-hang where the window never
    /// appeared), output piped and drained, stderr discarded, and a hard
    /// deadline after which the child is terminated. Nothing about a GUI
    /// launch context may block this unboundedly.
    private static func run(_ command: String, timeout: TimeInterval) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", command]
        proc.standardInput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        let out = Pipe()
        proc.standardOutput = out
        // Drain concurrently: a chatty .zshrc past the pipe buffer would
        // deadlock a wait-first order.
        let drained = DispatchSemaphore(value: 0)
        var data = Data()
        DispatchQueue.global(qos: .utility).async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        let exited = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exited.signal() }
        do { try proc.run() } catch { return nil }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            if exited.wait(timeout: .now() + 0.3) == .timedOut { return nil }
        }
        _ = drained.wait(timeout: .now() + 1)
        return String(data: data, encoding: .utf8)
    }

    /// Interactive capture first (the toolchain PATH lives in .zshrc),
    /// non-interactive as fallback; both from a CLEAN parent environment
    /// so inherited launch context neither helps nor hides. A capture
    /// that yields fewer than ~20 lines was not a real user shell.
    private static let captured: [String] = {
        let home = ProcessInfo.processInfo.environment["HOME"]
            ?? NSHomeDirectory()
        let base = "HOME=\(Shell.forceQuoted(home)) USER=\(NSUserName()) "
            + "LOGNAME=\(NSUserName()) SHELL=/bin/zsh TERM=dumb"
        for (command, budget) in [("/bin/zsh -l -i -c env", 8.0),
                                  ("/bin/zsh -l -c env", 3.0)] {
            guard let output = run("/usr/bin/env -i \(base) " + command, timeout: budget),
                  output.split(separator: "\n").count >= 20 else { continue }
            return output.split(separator: "\n").map(String.init)
        }
        return []
    }()

    /// Captured user env layered over the process environment. Values
    /// with `=` survive (maxSplits 1); junk lines without `=` drop.
    static let asDictionary: [String: String] = {
        var merged = ProcessInfo.processInfo.environment
        for line in captured {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            merged[String(parts[0])] = String(parts[1])
        }
        return merged
    }()

    /// Warm the (multi-second, interactive-shell) capture off the main
    /// thread at app start, so the first agent pane does not pay for it.
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async { _ = asDictionary }
    }
}

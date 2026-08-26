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
struct PaneState: Codable {
    let id: String        // pane UUID (stable, persisted)
    var cwd: String?
    /// Grid-cell geometry (normalized at layout time).
    var left: Int = 0
    var top: Int = 0
    var width: Int = 1
    var height: Int = 1
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

    var focusedTab: TabState? {
        tabs.indices.contains(focusedTabIndex) ? tabs[focusedTabIndex] : nil
    }

    var isRemote: Bool { sshHost != nil }

    /// Display name: the host alias for servers, "Local" for this Mac —
    /// derived, never stored, so no state migration can ever be needed.
    var displayName: String { isRemote ? name : "Local" }
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

/// The user's login-shell environment, captured once at first use. A GUI
/// launched from launchd/automation inherits a minimal env; the user's zshrc
/// (oh-my-zsh, prompts, version managers) misbehaves or hangs without the
/// real PATH. Without this, shells hang mid-init and never print a prompt.
enum UserShellEnv {
    static let cached: [String] = {
        String(data: Shell.exec("/bin/zsh -l -c env").stdout, encoding: .utf8)?
            .split(separator: "\n")
            .map(String.init) ?? []
    }()

    /// KEY=VALUE lines parsed into a dictionary for SurfaceConfiguration.
    static let asDictionary: [String: String] = Dictionary(uniqueKeysWithValues: cached.compactMap {
        let parts = $0.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    })
}

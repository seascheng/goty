// goty — see CLAUDE.md for the working principles.
import Foundation

// MARK: - Git status for sidebar space rows

/// Branch plus working-tree diff counts for one repo (tty7's sidebar
/// git line). `nil` summary = "not a repo / not reachable".
struct GitSummary: Equatable {
    let branch: String
    let added: Int
    let removed: Int
}

/// Sidebar space rows' git line: branch + diff counts per repo.
/// Freshness machinery lives in `GitRepoCache` (shared with ScmStore —
/// one engine, not two copies); this store owns WHAT to ask (one
/// round trip: root, worktree list, branch, shortstat) and the parse.
final class GitStatusStore {
    static let shared = GitStatusStore()

    private let engine: GitRepoCache<GitSummary>
    /// A summary CHANGED (poll or RepoWatcher path) — the sidebar
    /// re-renders its spaces.
    var onSummaryChanged: (() -> Void)? {
        didSet { engine.onValuesChanged = onSummaryChanged }
    }

    init() {
        engine = GitRepoCache { cwd, host in
            Self.fetch(cwd: cwd, host: host).map {
                GitRepoCache<GitSummary>.Answer(root: $0.root, spaceRoot: $0.spaceRoot,
                                                value: $0.summary)
            }
        }
    }

    /// Last known summary for a cwd (main thread).
    func summary(for cwd: String, host: String?) -> GitSummary? {
        engine.answer(cwd: cwd, host: host)?.value
    }

    /// The SPACE root for a cwd — the engine's one definition (see
    /// `GitRepoCache.spaceRoot`).
    func spaceRoot(for cwd: String, host: String?) -> String? {
        engine.spaceRoot(cwd: cwd, host: host)
    }

    /// Re-fetches the given cwds if stale. `onChange` fires on the main
    /// thread when at least one summary changed — the caller re-renders
    /// the sidebar's spaces only (change-domain `.git`). `force` skips
    /// the TTL (after an SCM panel op moved refs).
    func refresh(cwds: [String], host: String?, force: Bool = false,
                 onChange: (() -> Void)? = nil) {
        engine.refresh(cwds: cwds, host: host, force: force) { changed, _ in
            if changed { onChange?() }
        }
    }

    /// RepoWatcher: this LOCAL repo changed on disk — the engine
    /// refetches every cwd of the root, rate-bounded. Fires
    /// `onSummaryChanged` only when a value moved.
    func rootChanged(root: String) { engine.rootChanged(root: root) }

    /// One round trip: repo root (rev-parse — also the watcher's key),
    /// branch (symbolic-ref, short hash when detached), then
    /// worktree-vs-HEAD shortstat (plain diff on an unborn HEAD), then
    /// `worktree list --porcelain` — its FIRST entry is the main
    /// worktree, the space identity subdirs and linked worktrees share.
    /// Fails closed (`nil`) outside a repo.
    static func fetch(cwd: String, host: String?) -> (root: String, spaceRoot: String, summary: GitSummary?)? {
        let dir = Shell.forceQuoted(cwd)
        let git = host != nil ? "git" : "/usr/bin/git"
        let command = "cd \(dir) && "
            + "\(git) rev-parse --show-toplevel && "
            + "{ \(git) symbolic-ref --short HEAD || \(git) rev-parse --short HEAD; } && "
            + "{ \(git) diff HEAD --shortstat || \(git) diff --shortstat; } && "
            + "{ \(git) worktree list --porcelain || true; } || exit 1"
        let result = Shell.exec(command, host: host)
        guard result.code == 0,
              let text = String(data: result.stdout, encoding: .utf8) else { return nil }

        var lines = text.split(separator: "\n").map(String.init)
        guard let root = lines.first?.trimmingCharacters(in: .whitespaces),
              !root.isEmpty else { return nil }
        lines.removeFirst()
        guard let branch = lines.first?.trimmingCharacters(in: .whitespaces),
              !branch.isEmpty else { return nil }
        lines.removeFirst()
        let stat = lines.first.map(parseShortstat) ?? (0, 0)
        // The space identity: `worktree list` names the main worktree
        // first — every cwd of the repo (subdir or linked worktree)
        // collapses onto it. Absent block (old git) degrades to the
        // local root: subdirs still group, worktrees stay apart. NOT
        // position-based: a clean tree emits NO shortstat line, so the
        // worktree block can start one line early.
        let spaceRoot = lines.first { $0.hasPrefix("worktree ") }
            .map { String($0.dropFirst("worktree ".count)) } ?? root
        return (root, spaceRoot, GitSummary(branch: branch, added: stat.0, removed: stat.1))
    }

    /// " 3 files changed, 10 insertions(+), 2 deletions(-)" → (10, 2).
    static func parseShortstat(_ line: String) -> (Int, Int) {
        var added = 0, removed = 0
        for part in line.split(whereSeparator: { ",()".contains($0) }) {
            let tokens = part.split(separator: " ")
            guard tokens.count == 2, let n = Int(tokens[0]) else { continue }
            if tokens[1].hasPrefix("insertion") { added = n }
            if tokens[1].hasPrefix("deletion") { removed = n }
        }
        return (added, removed)
    }
}

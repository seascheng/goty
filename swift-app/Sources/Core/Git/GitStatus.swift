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

/// Repo status cache behind the sidebar's space rows.
///
/// One fetch per distinct cwd — local repos via `/usr/bin/git`, remote
/// workspaces via a single ssh exec (branch + shortstat in one round
/// trip). Fetches run on a private serial queue; the cache itself is
/// only touched on the main thread (reads happen during row renders).
/// A TTL plus an in-flight set keep the poll cheap. LOCAL repos ride
/// RepoWatcher (FSEvents): their TTL is a 30s safety net against a
/// dropped kernel event, and a change refetches on the next 2s tick —
/// remote repos have no event source over ssh exec and keep the 5s
/// poll.
final class GitStatusStore {
    static let shared = GitStatusStore()

    private var cache: [String: GitSummary?] = [:]
    /// cwd memo → repo root (nil = known not-a-repo). Root-scoped
    /// invalidation (`RepoWatcher`) needs the mapping.
    private var rootFor: [String: String?] = [:]
    private var fetchedAt: [String: Date] = [:]
    private var inFlight = Set<String>()
    /// Last RepoWatcher-driven refetch per root (storm bound).
    private var eventRefetchedAt: [String: Date] = [:]
    static let eventMinInterval: TimeInterval = 3
    /// A summary CHANGED (poll or RepoWatcher path) — the sidebar
    /// re-renders its spaces.
    var onSummaryChanged: (() -> Void)?
    private let localTTL: TimeInterval
    private let remoteTTL: TimeInterval
    private let queue = DispatchQueue(label: "goty.git-status", qos: .utility)

    init(remoteTTL: TimeInterval = 5, localTTL: TimeInterval = 30) {
        self.remoteTTL = remoteTTL
        self.localTTL = localTTL
    }

    private func ttl(host: String?) -> TimeInterval { host == nil ? localTTL : remoteTTL }

    /// Last known summary for a cwd (main thread).
    func summary(for cwd: String) -> GitSummary? {
        cache[cwd] ?? nil
    }

    /// Re-fetches the given cwds if stale. `onChange` fires on the main
    /// thread when at least one summary changed — the caller re-renders
    /// the sidebar's spaces only (change-domain `.git`). `force` skips
    /// the TTL (after an SCM panel op moved refs).
    func refresh(cwds: [String], host: String?, force: Bool = false,
                 onChange: (() -> Void)? = nil) {
        let now = Date()
        var stale: [String] = []
        for cwd in Set(cwds)
        where force || fetchedAt[cwd].map({ now.timeIntervalSince($0) > ttl(host: host) }) ?? true {
            if !inFlight.contains(cwd) {
                inFlight.insert(cwd)
                stale.append(cwd)
            }
        }
        guard !stale.isEmpty else { return }

        queue.async { [weak self] in
            var changed = false
            var results: [String: (root: String, summary: GitSummary?)?] = [:]
            for cwd in stale {
                results[cwd] = Self.fetch(cwd: cwd, host: host)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                for (cwd, fetched) in results {
                    let summary = fetched.flatMap(\.summary)
                    if (self.cache[cwd] ?? nil) != summary { changed = true }
                    self.cache[cwd] = summary
                    self.rootFor[cwd] = fetched?.root
                    self.fetchedAt[cwd] = now
                    self.inFlight.remove(cwd)
                    // Local roots gain an FSEvents stream the first
                    // time they resolve; changes then invalidate via
                    // RepoWatcher instead of the clock.
                    if host == nil, let root = fetched?.root {
                        RepoWatcher.shared.watch(root)
                    }
                }
                if changed { onChange?(); self.onSummaryChanged?() }
            }
        }
    }

    /// RepoWatcher: this LOCAL repo changed on disk. Refetch every cwd
    /// that resolves to it NOW, rate-bounded per root; `force` rides
    /// past the TTL. Repos never seen (empty mapping) stay with the
    /// tick. `onSummaryChanged` fires only when a badge value moved.
    func rootChanged(root: String) {
        let now = Date()
        guard now.timeIntervalSince(eventRefetchedAt[root] ?? .distantPast)
                >= Self.eventMinInterval else { return }
        let cwds = rootFor.compactMap { ($0.value ?? nil) == root ? $0.key : nil }
        guard !cwds.isEmpty else { return }
        eventRefetchedAt[root] = now
        refresh(cwds: cwds, host: nil, force: true)
    }

    /// One round trip: repo root (rev-parse — also the watcher's key),
    /// branch (symbolic-ref, short hash when detached), then
    /// worktree-vs-HEAD shortstat (plain diff on an unborn HEAD).
    /// Fails closed (`nil`) outside a repo.
    static func fetch(cwd: String, host: String?) -> (root: String, summary: GitSummary?)? {
        let dir = Shell.forceQuoted(cwd)
        let git = host != nil ? "git" : "/usr/bin/git"
        let command = "cd \(dir) && "
            + "\(git) rev-parse --show-toplevel && "
            + "{ \(git) symbolic-ref --short HEAD || \(git) rev-parse --short HEAD; } && "
            + "{ \(git) diff HEAD --shortstat || \(git) diff --shortstat; } || exit 1"
        let proc = Process()
        if let host {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = SshTransport.options(host: host, command: command)
        } else {
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = ["-c", command]
        }
        proc.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        proc.standardOutput = pipe
        do {
            try proc.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return nil }

        var lines = text.split(separator: "\n").map(String.init)
        guard let root = lines.first?.trimmingCharacters(in: .whitespaces),
              !root.isEmpty else { return nil }
        lines.removeFirst()
        guard let branch = lines.first?.trimmingCharacters(in: .whitespaces),
              !branch.isEmpty else { return nil }
        lines.removeFirst()
        let stat = lines.first.map(parseShortstat) ?? (0, 0)
        return (root, GitSummary(branch: branch, added: stat.0, removed: stat.1))
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

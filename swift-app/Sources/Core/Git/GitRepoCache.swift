// goty — see CLAUDE.md for the working principles.
import Foundation

// MARK: - The one git cache engine

/// "Ask git about a directory, keep the answer fresh" — implemented
/// ONCE. GitStatusStore (sidebar summaries) and ScmStore (panel
/// status) used to carry near-line-for-line copies of this machinery;
/// the space-identity change (2026-08-25) had to be made in both,
/// which is how the duplication was caught. Stores now provide only a
/// fetch (what to run, what to keep); the engine owns:
///
/// - cwd memo: one answer per (host, cwd); nil = known not-a-repo
/// - TTL: local 30s (RepoWatcher keeps answers hot, the clock is only
///   a dropped-event safety net) / remote 5s (no event source over
///   ssh exec)
/// - in-flight dedup, timestamps taken at REQUEST time (a slow answer
///   must not re-arm the poll)
/// - RepoWatcher wiring for local roots
/// - root-scoped invalidation + rate-bounded event refetch
///
/// All state main-thread only; fetches run on one serial queue. The
/// fetch closure must be pure of the store (no self capture — the
/// engine outlives nothing, but a cycle here would be silent).
final class GitRepoCache<Value: Equatable> {
    struct Answer {
        /// The worktree-local toplevel (`rev-parse --show-toplevel`).
        let root: String
        /// The repo's MAIN worktree root — the space identity shared
        /// by every subdir and linked worktree of the repo.
        let spaceRoot: String?
        let value: Value?
    }
    typealias Fetch = (_ cwd: String, _ host: String?) -> Answer?

    /// TTLs as instance constants — Swift forbids static stored
    /// properties in generic types. Local 30s (RepoWatcher keeps
    /// answers hot, the clock is only a dropped-event safety net);
    /// remote 5s (no event source over ssh exec).
    let localTTL: TimeInterval = 30
    let remoteTTL: TimeInterval = 5
    /// RepoWatcher storm bound: at most one refetch window per root.
    let eventMinInterval: TimeInterval = 3

    private let fetch: Fetch
    /// Values landed AND changed (poll or RepoWatcher path).
    var onValuesChanged: (() -> Void)?

    private var answers: [String: Answer?] = [:]
    private var fetchedAt: [String: Date] = [:]
    private var inFlight = Set<String>()
    private var eventRefetchedAt: [String: Date] = [:]
    private let queue = DispatchQueue(label: "goty.git", qos: .userInitiated)

    init(fetch: @escaping Fetch) { self.fetch = fetch }

    private static func key(_ cwd: String, _ host: String?) -> String {
        (host ?? "") + "\u{0}" + cwd
    }

    // MARK: reads (main thread)

    /// Last known answer for a cwd; nil = unknown or known not-a-repo.
    func answer(cwd: String, host: String?) -> Answer? {
        answers[Self.key(cwd, host)] ?? nil
    }

    /// The SPACE seam — the one definition of "which space is this
    /// directory in": the repo's main worktree root when inside a
    /// known repo, nil otherwise (callers fall back to the raw path
    /// until a fetch lands). A cwd under an already-known root
    /// resolves instantly — cd-ing within a repo must not flash a
    /// different grouping while the fetch is in flight.
    func spaceRoot(cwd: String, host: String?) -> String? {
        if let direct = answer(cwd: cwd, host: host)?.spaceRoot { return direct }
        let prefix = (host ?? "") + "\u{0}"
        for (k, a) in answers where k.hasPrefix(prefix) {
            guard let root = a?.spaceRoot, cwd.hasPrefix(root + "/") else { continue }
            return root
        }
        return nil
    }

    // MARK: refresh

    /// Fetch every stale cwd, then answer all requested ones.
    /// `completion` fires ONCE on the main thread — synchronously when
    /// nothing was stale (the surface tick: cache read, no exec) —
    /// with each cwd's answer (cached or fresh) and whether any value
    /// changed. `force` rides past the TTL and the in-flight dedup.
    func refresh(cwds: [String], host: String?, force: Bool = false,
                 completion: ((_ changed: Bool, _ results: [String: Answer?]) -> Void)? = nil) {
        let ttl = host == nil ? localTTL : remoteTTL
        var stale: [String] = []
        for cwd in Set(cwds) {
            let k = Self.key(cwd, host)
            let fresh = fetchedAt[k].map { Date().timeIntervalSince($0) <= ttl } ?? false
            if force || !fresh {
                if force || !inFlight.contains(k) {
                    inFlight.insert(k)
                    fetchedAt[k] = Date()
                    stale.append(cwd)
                }
            }
        }
        guard !stale.isEmpty else {
            completion?(false, Self.results(cwds: cwds, host: host, from: answers))
            return
        }
        queue.async {
            var fetched: [String: Answer?] = [:]
            for cwd in stale {
                fetched[cwd] = self.fetch(cwd, host)
            }
            DispatchQueue.main.async {
                var changed = false
                for (cwd, answer) in fetched {
                    let k = Self.key(cwd, host)
                    let old = self.answers[k] ?? nil
                    self.answers[k] = answer
                    self.inFlight.remove(k)
                    if let root = answer?.root, host == nil {
                        RepoWatcher.shared.watch(root)
                    }
                    if old?.value != answer?.value { changed = true }
                }
                if changed { self.onValuesChanged?() }
                completion?(changed, Self.results(cwds: cwds, host: host, from: self.answers))
            }
        }
    }

    /// Drop the TTL for every cwd that resolved to this repo — the
    /// next poll refetches immediately (after a write op).
    func invalidate(root: String, host: String?) {
        for (k, a) in answers where a?.root == root {
            fetchedAt.removeValue(forKey: k)
        }
    }

    /// RepoWatcher: this LOCAL repo changed on disk. Refetch every cwd
    /// that resolves to it NOW (not at tick cadence), rate-bounded per
    /// root — a build storm costs at most one exec window per
    /// `eventMinInterval`; an idle repo costs zero. Roots never
    /// answered stay with the tick (nothing is showing them).
    func rootChanged(root: String, onLanded: (() -> Void)? = nil) {
        let now = Date()
        guard now.timeIntervalSince(eventRefetchedAt[root] ?? .distantPast)
                >= eventMinInterval else { return }
        // Local-only path: keys are "\0" + cwd.
        let cwds = answers.compactMap { (k, a) -> String? in
            a?.root == root ? String(k.dropFirst(1)) : nil
        }
        guard !cwds.isEmpty else { return }
        eventRefetchedAt[root] = now
        refresh(cwds: cwds, host: nil, force: true) { _, _ in onLanded?() }
    }

    private static func results(cwds: [String], host: String?,
                                from answers: [String: Answer?]) -> [String: Answer?] {
        var out: [String: Answer?] = [:]
        for cwd in cwds { out[cwd] = answers[key(cwd, host)] ?? nil }
        return out
    }
}

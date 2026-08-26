// goty — see CLAUDE.md for the working principles.
import Foundation

// MARK: - Source control model (tty7 scm, local/remote isomorphic)

/// One half of porcelain v2's `XY` pair.
enum ScmChangeCode: Equatable {
    case none, modified, typeChanged, added, deleted, renamed, copied, unmerged

    init?(byte: Character) {
        switch byte {
        case ".", " ": self = .none
        case "M": self = .modified
        case "T": self = .typeChanged
        case "A": self = .added
        case "D": self = .deleted
        case "R": self = .renamed
        case "C": self = .copied
        case "U": self = .unmerged
        default: return nil
        }
    }

    var isChange: Bool { self != .none }
}

/// The `XY` pairs porcelain v2 reports as unmerged (`u`) records.
enum ScmConflict: Equatable {
    case bothDeleted, addedByUs, deletedByThem, addedByThem
    case deletedByUs, bothAdded, bothModified

    init?(x: Character, y: Character) {
        switch (x, y) {
        case ("D", "D"): self = .bothDeleted
        case ("A", "U"): self = .addedByUs
        case ("U", "D"): self = .deletedByThem
        case ("U", "A"): self = .addedByThem
        case ("D", "U"): self = .deletedByUs
        case ("A", "A"): self = .bothAdded
        case ("U", "U"): self = .bothModified
        default: return nil
        }
    }
}

/// Where HEAD is — decides how "unstage" must be spelled (`git reset
/// HEAD` fails on an unborn branch; the index entry is dropped instead).
enum ScmHead: Equatable {
    case unborn(branch: String)
    case detached(oid: String)
    case branch(name: String, oid: String)

    /// What the chrome shows: branch name, or a short sha when detached.
    var label: String {
        switch self {
        case .unborn(let b): return b
        case .detached(let oid): return String(oid.prefix(7))
        case .branch(let name, _): return name
        }
    }

    var hasCommits: Bool {
        if case .unborn = self { return false }
        return true
    }
}

/// One `git status` entry. Paths are repo-root-relative, `/`-separated,
/// raw (never C-quoted — we ask for `-z`).
struct ScmEntry: Equatable {
    let path: String
    /// The OLD path of a rename/copy; absent otherwise.
    var origPath: String?
    /// `X` — HEAD vs index: what is staged.
    let index: ScmChangeCode
    /// `Y` — index vs worktree: what is not staged.
    let worktree: ScmChangeCode
    let isUntracked: Bool
    let conflict: ScmConflict?

    /// Staged AND unstaged at once (`MM`) appears in both groups — same
    /// rule VS Code shows.
    var isStaged: Bool { index.isChange && conflict == nil }
    var isUnstaged: Bool { worktree.isChange && conflict == nil && !isUntracked }
    var isConflicted: Bool { conflict != nil }
}

/// The whole working-tree picture. One `--porcelain=v2 --branch` run.
struct ScmStatus: Equatable {
    let root: String
    let head: ScmHead
    let upstream: String?
    /// nil = unknown, never "in sync" — `+? -?` must not read as 0/0.
    let ahead: Int?
    let behind: Int?
    let entries: [ScmEntry]
    let totalEntries: Int
    /// Entries past `ScmParser.maxEntries` were dropped.
    let truncated: Bool
    /// `git worktree list --porcelain`, same round trip as status —
    /// the Git panel's Worktrees group. Empty when the worktree block
    /// was absent (old payload / git without worktree support).
    var worktrees: [WorktreeRecord] = []

    var staged: [ScmEntry] { entries.filter(\.isStaged) }
    var unstaged: [ScmEntry] { entries.filter(\.isUnstaged) }
    var untracked: [ScmEntry] { entries.filter(\.isUntracked) }
    var conflicts: [ScmEntry] { entries.filter(\.isConflicted) }
}

// MARK: - Parser (pure — the whole point is testability without a repo)

enum ScmParser {
    /// tty7: past this the list is dropped but `totalEntries` still tells
    /// the panel to say so instead of showing a quietly short list.
    static let maxEntries = 10_000

    /// Parse the stdout of `git status --porcelain=v2 --branch -uall -z`
    /// (NUL-separated records; field 0 is the repo root from a preceding
    /// `rev-parse -z --show-toplevel`). Never fails — malformed records
    /// are dropped, a missing row beats no panel. `worktrees` rides the
    /// same payload (see `ScmStore.parseTransport`).
    static func parse(root: String, records: [String],
                      worktrees: [WorktreeRecord] = []) -> ScmStatus {
        var oid: String?
        var headName: String?
        var upstream: String?
        var ahead: Int?
        var behind: Int?
        var entries: [ScmEntry] = []
        var total = 0

        var i = 0
        while i < records.count {
            let r = records[i]
            i += 1
            if r.hasPrefix("# branch.oid ") {
                oid = String(r.dropFirst("# branch.oid ".count))
            } else if r.hasPrefix("# branch.head ") {
                headName = String(r.dropFirst("# branch.head ".count))
            } else if r.hasPrefix("# branch.upstream ") {
                upstream = String(r.dropFirst("# branch.upstream ".count))
            } else if r.hasPrefix("# branch.ab ") {
                let pair = parseAB(String(r.dropFirst("# branch.ab ".count)))
                ahead = pair?.0
                behind = pair?.1
            } else if r.hasPrefix("1 ") {
                // 1 XY sub mH mI mW hH hI <path>
                if let f = fields(r, expected: 8) {
                    appendEntry(&entries, &total, xy: f[1], path: f[8],
                                origPath: nil, untracked: false)
                }
            } else if r.hasPrefix("2 ") {
                // 2 XY sub mH mI mW hH hI Xscore <path> NUL <origPath>
                if let f = fields(r, expected: 9) {
                    let orig = i < records.count ? records[i] : nil
                    if orig != nil { i += 1 }
                    appendEntry(&entries, &total, xy: f[1], path: f[9],
                                origPath: orig, untracked: false)
                }
            } else if r.hasPrefix("u ") {
                // u XY sub m1 m2 m3 mW h1 h2 h3 <path>
                if let f = fields(r, expected: 10) {
                    appendEntry(&entries, &total, xy: f[1], path: f[10],
                                origPath: nil, untracked: false)
                }
            } else if r.hasPrefix("? ") {
                let path = String(r.dropFirst(2))
                if !path.isEmpty {
                    appendEntry(&entries, &total, xy: "..", path: path,
                                origPath: nil, untracked: true)
                }
            }
            // `!` ignored records: not requested; unknown headers: future git.
        }

        let head: ScmHead
        switch (oid, headName) {
        case (nil, nil), ("(initial)", nil):
            head = .unborn(branch: "")
        case ("(initial)", let name?):
            head = .unborn(branch: name)
        case (let o?, "(detached)"):
            head = .detached(oid: o)
        case (let o?, let name?):
            head = .branch(name: name, oid: o)
        default:
            head = .detached(oid: "")
        }
        let truncated = total > maxEntries
        return ScmStatus(root: root, head: head, upstream: upstream,
                         ahead: ahead, behind: behind, entries: entries,
                         totalEntries: total, truncated: truncated,
                         worktrees: worktrees)
    }
    /// `+2 -1` → (2, 1); `+? -?` (no upstream / aheadBehind off) → nil.
    static func parseAB(_ value: String) -> (Int, Int)? {
        var ahead: Int?
        var behind: Int?
        for token in value.split(separator: " ") {
            if token.hasPrefix("+") { ahead = Int(token.dropFirst()) }
            if token.hasPrefix("-") { behind = Int(token.dropFirst()) }
        }
        guard let ahead, let behind else { return nil }
        return (ahead, behind)
    }

    /// Space-split the fixed head of a record, handing back the rest
    /// verbatim — the path is last and may contain spaces (but never a
    /// NUL, which is why `-z` is not optional).
    private static func fields(_ record: String, expected: Int) -> [String]? {
        var out: [String] = []
        var rest = Substring(record)
        for _ in 0..<expected {
            guard let space = rest.firstIndex(of: " ") else { return nil }
            out.append(String(rest[..<space]))
            rest = rest[rest.index(after: space)...]
        }
        out.append(String(rest))
        return out
    }

    private static func appendEntry(_ entries: inout [ScmEntry], _ total: inout Int,
                                    xy: String, path: String, origPath: String?,
                                    untracked: Bool) {
        guard path.first != "\0" else { return }
        total += 1
        guard entries.count < maxEntries else { return }
        let x = xy.first.flatMap { ScmChangeCode(byte: $0) } ?? .none
        let y = xy.last.flatMap { ScmChangeCode(byte: $0) } ?? .none
        let conflict = xy.count == 2
            ? (xy.first.flatMap { x in xy.last.map { y in ScmConflict(x: x, y: y) } }) ?? nil
            : nil
        entries.append(ScmEntry(path: path, origPath: origPath, index: x,
                                worktree: y, isUntracked: untracked,
                                conflict: conflict))
    }
}

// MARK: - File-tree decorations (one definition, shared everywhere)

/// How a path is decorated wherever one status stands for a file. Raw
/// value is display precedence — a directory takes the max beneath it,
/// so one conflict colors the whole path to the root.
enum ScmDeco: Int, Comparable, Equatable {
    case ignored = 0, untracked, added, modified, renamed, deleted, conflict

    static func < (lhs: ScmDeco, rhs: ScmDeco) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The letter in the badge column; ignored has none (a tree full of
    /// `!` is noise, not information — tty7's rule).
    var letter: String? {
        switch self {
        case .ignored: return nil
        case .untracked: return "U"
        case .added: return "A"
        case .modified: return "M"
        case .renamed: return "R"
        case .deleted: return "D"
        case .conflict: return "C"
        }
    }

    static func worse(_ a: ScmDeco, _ b: ScmDeco) -> ScmDeco { a >= b ? a : b }

    static func deco(index: ScmChangeCode, worktree: ScmChangeCode,
                     untracked: Bool, conflict: ScmConflict?) -> ScmDeco {
        if conflict != nil { return .conflict }
        if untracked { return .untracked }
        func rank(_ c: ScmChangeCode) -> Int {
            switch c {
            case .none: return 0
            case .modified, .typeChanged: return 1
            case .copied: return 2
            case .renamed: return 3
            case .added: return 4
            case .deleted: return 5
            case .unmerged: return 6
            }
        }
        let worseCode = rank(worktree) >= rank(index) ? worktree : index
        switch worseCode {
        case .deleted: return .deleted
        case .added: return .added
        case .renamed, .copied: return .renamed
        case .unmerged: return .conflict
        default: return .modified
        }
    }
}

struct ScmDirRollup: Equatable {
    var changed = false
    var conflict = false

    mutating func merge(_ deco: ScmDeco) {
        if deco == .conflict { conflict = true }
        if deco != .ignored { changed = true }
    }
}

/// Repo-root-relative lookup for the file tree, built once per refresh
/// on a background thread; the render path only probes.
struct ScmDecoIndex: Equatable {
    let root: String
    private let files: [String: ScmDeco]
    private let dirs: [String: ScmDirRollup]

    /// tty7: past this many changed files the per-file map is dropped and
    /// only directories stay decorated.
    static let maxDecoratedFiles = 5_000

    static func build(_ status: ScmStatus) -> ScmDecoIndex {
        var files: [String: ScmDeco] = [:]
        var dirs: [String: ScmDirRollup] = [:]

        func rollup(_ path: String, _ deco: ScmDeco) {
            var cut = Substring(path)
            while let slash = cut.lastIndex(of: "/") {
                cut = cut[..<slash]
                dirs[String(cut), default: ScmDirRollup()].merge(deco)
            }
        }

        for e in status.entries {
            let deco = ScmDeco.deco(index: e.index, worktree: e.worktree,
                                     untracked: e.isUntracked, conflict: e.conflict)
            files[e.path] = ScmDeco.worse(files[e.path] ?? deco, deco)
            rollup(e.path, deco)
            // A rename's old path only rolls up — the path can be
            // occupied again, and that row belongs to its occupant.
            if let orig = e.origPath { rollup(orig, deco) }
        }
        if files.count > maxDecoratedFiles { files.removeAll() }
        return ScmDecoIndex(root: status.root, files: files, dirs: dirs)
    }

    func file(_ repoRel: String) -> ScmDeco? { files[repoRel] }
    func dir(_ repoRel: String) -> ScmDirRollup? { dirs[repoRel] }
}

// MARK: - Operations (argv construction is pure; tty7 GitOp)

enum ScmLoss: Equatable {
    case worktreeEdits
    case untrackedFiles
}

/// One source-control verb. `headHasCommits` rides along because the one
/// command that genuinely differs — unstage — needs no version probe to
/// decide (tty7's rule: pass HEAD in, keep the builder pure).
enum ScmOp: Equatable {
    case stage(paths: [String])
    case stageAll
    case unstage(paths: [String], headHasCommits: Bool)
    case unstageAll(headHasCommits: Bool)
    /// `git checkout --` on tracked files.
    case discardWorktree(paths: [String])
    /// `git clean` on untracked ones.
    case discardUntracked(paths: [String], directories: Bool)
    /// `all` = `-a`: stage every tracked change, then commit.
    case commit(message: String, all: Bool)

    var label: String {
        switch self {
        case .stage, .stageAll: return "stage"
        case .unstage, .unstageAll: return "unstage"
        case .discardWorktree, .discardUntracked: return "discard"
        case .commit: return "commit"
        }
    }

    /// What the user stands to lose — the UI's confirmation gate.
    var loss: ScmLoss? {
        switch self {
        case .discardWorktree: return .worktreeEdits
        case .discardUntracked: return .untrackedFiles
        default: return nil
        }
    }

    /// Every git argv this op runs, in order, RELATIVE to the repo root.
    /// More than one only because a long path list is batched. The old
    /// spellings throughout (`checkout --`, `reset HEAD --`) — tty7's
    /// reasoning: `restore` is still documented EXPERIMENTAL and has
    /// moved across releases; the old forms haven't in a decade, and a
    /// remote dev box is not guaranteed new.
    func commands() -> [[String]] {
        switch self {
        case .stage(let paths):
            return batched(["add"], paths)
        case .stageAll:
            return [["add", "-A", "--", "."]]
        case .unstage(let paths, let hasCommits):
            return batched(hasCommits ? ["reset", "-q", "HEAD"] : ["rm", "--cached", "-r", "-q", "-f"],
                           paths)
        case .unstageAll(let hasCommits):
            let prefix = hasCommits ? ["reset", "-q", "HEAD"] : ["rm", "--cached", "-r", "-q", "-f"]
            return batched(prefix, ["."])
        case .discardWorktree(let paths):
            return batched(["checkout"], paths)
        case .discardUntracked(let paths, let directories):
            return batched(["clean", directories ? "-fd" : "-f", "-q"], paths)
        case .commit(let message, let all):
            var out = ["commit"]
            if all { out.append("-a") }
            if message.isEmpty {
                // A merge commit whose message the user cleared still has
                // to be committable (tty7's edge).
                out.append("--allow-empty-message")
                out.append("-m")
                out.append("")
            } else {
                out.append("-m")
                out.append(message)
            }
            return [out]
        }
    }

    /// `:(literal)` is not decoration: without it git globs the pathspec,
    /// so `a[b].txt` or `foo*` would not match themselves. The `--` (in
    /// `batched`) keeps a file named `HEAD` or `-f` from reading as a
    /// rev or an option.
    private static func pathspec(_ path: String) -> String { ":(literal)" + path }

    /// `prefix -- <specs…>`, split so no single call overflows — by count
    /// (tty7's 200) whichever fills first.
    private func batched(_ prefix: [String], _ paths: [String]) -> [[String]] {
        var out: [[String]] = []
        var current = prefix + ["--"]
        for p in paths {
            current.append(Self.pathspec(p))
            if current.count >= 200 {
                out.append(current)
                current = prefix + ["--"]
            }
        }
        if current.count > prefix.count + 1 || out.isEmpty { out.append(current) }
        return out
    }
}


// MARK: - Store (cwd→root memo, root→status cache, serial writes)

struct ScmOpFailure: Error, Equatable {
    let op: String
    let detail: String
}

/// Anything `ScmStore.run` can execute: a label for error dialogs plus
/// the argv batches. `ScmOp` and `WorktreeOp` both conform — the store
/// keeps ONE execution path (serial queue, invalidation, first-failure
/// stops).
protocol ScmCommand {
    var label: String { get }
    func commands() -> [[String]]
}
extension ScmOp: ScmCommand {}
extension WorktreeOp: ScmCommand {}

/// The Git panel's data source. Freshness machinery lives in
/// `GitRepoCache` (shared with GitStatusStore — one engine, not two
/// copies); this store owns the round trip (root + porcelain status +
/// worktree list), the parse, and op execution.
final class ScmStore {
    static let shared = ScmStore()

    private let engine: GitRepoCache<ScmStatus>
    /// Write ops run on their own serial queue (reads/fetches own the
    /// engine's) — writes never interleave on the wire.
    private let opQueue = DispatchQueue(label: "goty.scm.ops", qos: .userInitiated)
    /// A RepoWatcher-driven refetch landed — surfaces re-render from
    /// cache (the fetch itself re-armed the TTL; no exec follows).
    var onRepoUpdated: ((String) -> Void)?

    init() {
        engine = GitRepoCache { cwd, host in
            let git = host != nil ? "git" : "/usr/bin/git"
            let dir = Shell.forceQuoted(cwd)
            // Three US (\u{1F})-separated sections — root, status, worktree
            // list — so ONE sh/ssh round trip feeds the panel's groups AND
            // its Worktrees section. The worktree block degrades to empty
            // on git without worktree support instead of killing status.
            let command = "cd \(dir) && "
                + "\(git) rev-parse --show-toplevel && printf '\\037' && "
                + "\(git) -c core.quotePath=false status --porcelain=v2 --branch "
                + "--untracked-files=all -z && printf '\\037' && "
                + "{ \(git) worktree list --porcelain || true; }"
            let result = Shell.exec(command, host: host)
            guard result.code == 0, let text = String(data: result.stdout, encoding: .utf8),
                  let parsed = Self.parseTransport(text) else { return nil }
            let mainRoot = parsed.worktrees.first(where: { !$0.bare })?.path ?? parsed.root
            return GitRepoCache<ScmStatus>.Answer(root: parsed.root, spaceRoot: mainRoot,
                                                  value: parsed)
        }
    }

    /// Last known status for the repo containing `cwd` (main thread).
    /// nil = not a repo, unreachable, or nothing fetched yet.
    func cachedStatus(cwd: String, host: String?) -> ScmStatus? {
        engine.answer(cwd: cwd, host: host)?.value
    }

    /// The root every write runs from; nil until a status has landed.
    func repoRoot(cwd: String, host: String?) -> String? {
        engine.answer(cwd: cwd, host: host)?.root
    }

    /// Resolve the repo root + fetch status in ONE round trip:
    /// `rev-parse -z --show-toplevel` then `status --porcelain=v2 -z`.
    /// `onChange` fires on the main thread when the answer landed —
    /// nil = not a repo / unreachable; the caller decides how to say so.
    func refreshStatus(cwd: String, host: String?, force: Bool = false,
                       onChange: ((ScmStatus?) -> Void)? = nil) {
        engine.refresh(cwds: [cwd], host: host, force: force) { _, results in
            onChange?((results[cwd] ?? nil)?.value)
        }
    }

    /// Run one operation, then invalidate every cache that could have
    /// moved. Batches run in order and stop at the first failure — a
    /// half-applied stage is recoverable; burying the reason is not.
    func run(op: ScmCommand, root: String, host: String?,
             completion: ((Result<Void, ScmOpFailure>) -> Void)? = nil) {
        opQueue.async { [weak self] in
            let git = host != nil ? "git" : "/usr/bin/git"
            let dir = Shell.forceQuoted(root)
            var failure: ScmOpFailure?
            for argv in op.commands() {
                let command = "cd \(dir) && " + git + " " + Shell.join(argv)
                let result = Shell.exec(command, host: host)
                if result.code != 0 {
                    let first = result.stderr
                        .split(separator: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .first(where: { !$0.isEmpty }) ?? ""
                    failure = ScmOpFailure(op: op.label,
                                           detail: first.isEmpty
                                               ? "git exited with status \(result.code)"
                                               : first)
                    break
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                // Everything about this repo is now stale: the panel's
                // status, the tree's badges, the sidebar's branch/counts.
                self.invalidate(root: root, host: host)
                completion?(failure.map { .failure($0) } ?? .success(()))
            }
        }
    }

    /// Drop the TTL for every cwd that resolved to this repo, so the next
    /// poll refetches immediately.
    func invalidate(root: String, host: String?) {
        engine.invalidate(root: root, host: host)
    }

    /// RepoWatcher: this LOCAL repo changed on disk — the engine
    /// refetches every cwd of the root, rate-bounded; the landing
    /// tells the surfaces to re-read.
    func rootChanged(root: String) {
        engine.rootChanged(root: root) { [weak self] in
            self?.onRepoUpdated?(root)
        }
    }

    /// The transport payload — three US (`\u{1F}`)-separated sections:
    /// `<root>\n` · NUL-terminated status records · worktree porcelain.
    /// (`rev-parse` has no `-z`; a root containing a newline would be
    /// ambiguous the same way it is for every line-based tool — accepted
    /// the same way.) A payload with NO US is the pre-worktree shape —
    /// status still parses, worktrees stay empty.
    static func parseTransport(_ text: String) -> ScmStatus? {
        let sections = text.split(separator: "\u{1F}", omittingEmptySubsequences: false)
        if sections.count == 3 {
            let root = sections[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !root.isEmpty, !root.contains(" "), !root.contains("fatal") else { return nil }
            let records = sections[1]
                .split(separator: "\u{0}", omittingEmptySubsequences: true)
                .map(String.init)
            return ScmParser.parse(root: root, records: records,
                                   worktrees: WorktreeList.parse(String(sections[2])))
        }
        guard let nl = text.firstIndex(of: "\n") else { return nil }
        let root = String(text[..<nl])
        guard !root.isEmpty, !root.contains(" "), !root.contains("fatal") else { return nil }
        let records = text[text.index(after: nl)...]
            .split(separator: "\u{0}", omittingEmptySubsequences: true)
            .map(String.init)
        return ScmParser.parse(root: root, records: records)
    }
}

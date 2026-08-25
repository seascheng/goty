// goty — see CLAUDE.md for the working principles.
import Foundation

// MARK: - Git worktrees (pure model — design: docs/specs/2026-08-23-worktree-design.md)

/// One `git worktree list --porcelain` record. `branch` is the SHORT
/// name (refs/heads/ stripped) — that is what `WorktreeOp.merge` takes
/// and what the panel shows; nil on detached/bare worktrees.
struct WorktreeRecord: Equatable {
    let path: String
    let head: String?
    let branch: String?
    let detached: Bool
    let bare: Bool
    /// The first record porcelain prints — the main working tree.
    let isMain: Bool
}

/// Parser for `git worktree list --porcelain`. Never fails — a record
/// without a `worktree` line is dropped, an unknown attribute line
/// (`locked`, `prunable`, future git) is ignored.
enum WorktreeList {
    static func parse(_ text: String) -> [WorktreeRecord] {
        var out: [WorktreeRecord] = []
        var path: String?
        var head: String?
        var branch: String?
        var detached = false
        var bare = false
        func flush() {
            guard let p = path else { return }
            out.append(WorktreeRecord(path: p, head: head,
                                      branch: branch.flatMap(shortBranch),
                                      detached: detached, bare: bare,
                                      isMain: out.isEmpty))
            path = nil; head = nil; branch = nil
            detached = false; bare = false
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = Substring(line)
            if l.isEmpty {
                flush()
            } else if l.hasPrefix("worktree ") {
                flush()
                path = String(l.dropFirst("worktree ".count))
            } else if l.hasPrefix("HEAD ") {
                head = String(l.dropFirst("HEAD ".count))
            } else if l.hasPrefix("branch ") {
                branch = String(l.dropFirst("branch ".count))
            } else if l == "detached" {
                detached = true
            } else if l == "bare" {
                bare = true
            }
        }
        flush()
        return out
    }

    /// `refs/heads/main` → `main`; anything else is not a local branch.
    static func shortBranch(_ ref: String) -> String? {
        ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : nil
    }
}

/// Where a new worktree lands and whether its name may become a branch.
enum WorktreePlan {
    /// Beside the REPO ROOT (the space's cwd may be a subdirectory):
    /// `/Users/x/code/goty` + `fix-login`
    /// → `/Users/x/code/goty-fix-login`. Trailing slashes on the
    /// root are normalized so the name never lands mid-path.
    static func target(root: String, name: String) -> String {
        let trimmed = root.hasSuffix("/") && root.count > 1
            ? String(root.dropLast()) : root
        let ns = trimmed as NSString
        return ns.deletingLastPathComponent + "/" + ns.lastPathComponent + "-" + name
    }

    /// Branch-name rules (check-ref-format, the practical subset).
    /// nil = valid; non-nil = why not, verbatim into the error dialog.
    static func validateName(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return "Name is empty." }
        if s.hasPrefix("-") { return "A branch name cannot start with \"-\"." }
        // A worktree name is one path component: no slash at all, and
        // "."/".." as the WHOLE name are the ambiguous ones a user
        // could actually type.
        if s == "." || s == ".." { return "\"\(s)\" is not a valid name." }
        if s.contains("/") { return "\"/\" is not allowed — the name is a single path component." }
        if s.hasSuffix(".lock") { return "Names ending in \".lock\" are reserved." }
        let bad: Set<Character> = [" ", "~", "^", ":", "?", "*", "[", "\\", "\t", "\n", "\r"]
        if let c = s.first(where: { bad.contains($0) }) {
            return "The character \"\(c)\" is not allowed in a branch name."
        }
        if s.contains(where: { $0.asciiValue.map { $0 < 0x20 } == true }) {
            return "Control characters are not allowed in a branch name."
        }
        return nil
    }
}


/// One worktree verb, same shape as `ScmOp`: argv is pure, execution
/// and cache invalidation stay in `ScmStore.run`.
enum WorktreeOp: Equatable {
    /// `git worktree add -b <branch> <path>` — branch from current HEAD.
    case create(path: String, branch: String)
    /// `git merge <branch> --no-edit` — bring a worktree's branch back
    /// into the repo the panel is showing.
    case merge(branch: String)
    /// `git worktree remove <path>` — never forced from the UI; a dirty
    /// worktree fails and the error says so.
    case remove(path: String)

    var label: String {
        switch self {
        case .create: return "worktree add"
        case .merge: return "merge"
        case .remove: return "worktree remove"
        }
    }

    /// Commands run from the repo root, in order. Absolute paths — no
    /// prefix guessing; quoting happens in `ScmTransport.join`.
    func commands() -> [[String]] {
        switch self {
        case .create(let path, let branch):
            return [["worktree", "add", "-b", branch, path]]
        case .merge(let branch):
            return [["merge", "--no-edit", branch]]
        case .remove(let path):
            return [["worktree", "remove", path]]
        }
    }
}

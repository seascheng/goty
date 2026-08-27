// goty — see CLAUDE.md for the working principles.
import GhosttyKit
import AppKit

extension AppDelegate {

    // MARK: Worktree creation (space "+" → "New Worktree…")

    /// Prompt for a name, create the worktree beside the repo, jump
    /// into it (design: docs/specs/2026-08-23-worktree-design.md).
    /// One tick after the menu action so the menu finishes closing
    /// first (same sequencing as the SSH manager entry; the dialog is
    /// a real modal session since 2026-08-23 and needs no such
    /// deferral to be safe).
    func startWorktreeFlow(cwd: String?) {
        guard let cwd, !cwd.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // The space's workspace is the focused one — the sidebar
            // renders only its sections.
            let host = self.coordinator.store?.focused?.sshHost
            func present(root: String) {
                // The designed card (2026-08-24) in its OWN window —
                // the SSH-manager recipe; live target preview + inline
                // validation, no post-hoc "Invalid name" round trip.
                WorktreeWindow.present(root: root, over: self.window) {
                    [weak self] name in
                    guard let self else { return }
                    self.coordinator.createWorktree(
                        name: name, cwd: cwd, host: host) { result in
                        if case .failure(let f) = result {
                            Dialog.error(title: "Git worktree failed",
                                         detail: f.detail)
                        }
                    }
                }
            }
            if let root = ScmStore.shared.repoRoot(cwd: cwd, host: host) {
                present(root: root)
                return
            }
            ScmStore.shared.refreshStatus(cwd: cwd, host: host, force: true) { st in
                guard let root = st?.root else {
                    Dialog.error(title: "Not a git repository",
                                 detail: "Worktrees need a git repository.")
                    return
                }
                present(root: root)
            }
        }
    }

    /// Rebuild the panel from the focused workspace (Info target + Files
    /// + Git roots). The Files tab follows the SPACE, not the pane cwd:
    /// one git repo is one space, so the tree roots at the repo's main
    /// worktree wherever the pane sits (subdir or linked worktree); the
    /// Git tab still follows the pane's own repo state. The space root
    /// arrives with the first git fetch for a new cwd — `gitSurfacesStale`
    /// re-runs this pass when it lands.
}

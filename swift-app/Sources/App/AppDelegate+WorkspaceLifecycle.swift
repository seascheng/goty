// goty — see CLAUDE.md for the working principles.
import GhosttyKit
import AppKit

extension AppDelegate {

    // MARK: workspace lifecycle (tty7 model: create + restore)

    /// Mode 1 close: drop the connection AND remove the server from the
    /// sidebar — every session keeps running on the machine (the remote
    /// daemon persists panes); teardown falls focus back to the local
    /// workspace. Re-adding the host reattaches them.
    func disconnectWorkspace(at index: Int) {
        guard let store = coordinator.store,
              store.workspaces.indices.contains(index) else { return }
        let ws = store.workspaces[index]
        guard ws.isRemote else { return }
        remoteLinks.removeValue(forKey: ws.id)?.stop()
        // Park: pane ids survive in state.json, so re-adding the host
        // reattaches the still-running sessions.
        coordinator.teardownWorkspace(ws.id, park: true)
    }

    /// Manual reconnect: coordinator state + immediate two-step link probe
    /// (1s TCP reachability first; ssh only when the host answers).
    func reconnectRemote(wsId: UUID) {
        coordinator.reconnectWorkspace(wsId)
        remoteLinks[wsId]?.reconnectNow()
    }

    func closeWorkspaceDialog(at index: Int) {
        guard let store = coordinator.store,
              store.workspaces.indices.contains(index) else { return }
        let workspace = store.workspaces[index]
        guard Dialog.confirm(
            title: "Close server \(workspace.displayName)?",
            detail: "Terminates its \(workspace.tabs.count) space(s) on "
                + (workspace.isRemote ? (workspace.sshHost ?? "?") : "this Mac") + ".",
            action: "Close & Remove") else { return }
        // Kill FIRST, drop the link after: killWorkspace resolves the
        // daemon from the still-live remote link — stopping first sent
        // the kills to the LOCAL daemon under remote pane ids (remote
        // sessions survived their own "Close").
        coordinator.killWorkspace(workspace.id)
        remoteLinks[workspace.id]?.stopRemoteDaemon()
        remoteLinks.removeValue(forKey: workspace.id)?.stop()
        coordinator.teardownWorkspace(workspace.id)
    }

    func removeWorkspaceDialog(at index: Int) {
        guard let store = coordinator.store,
              store.workspaces.indices.contains(index) else { return }
        let ws = store.workspaces[index]
        guard Dialog.confirm(
            title: "Remove server \(ws.displayName)?",
            detail: ws.isRemote
                ? "Unreachable, so nothing can be closed on \(ws.sshHost ?? "?"). "
                    + "The Goty session there KEEPS RUNNING — add the host again later to reattach."
                : "The local Goty session keeps running and can be reattached on next launch.",
            action: "Remove") else { return }

        // No workspace-local client remains; PaneHost/daemon teardown is below.
        // Park like Mode 1: the unreachable server's sessions keep running;
        // re-adding the host reattaches them.
        remoteLinks.removeValue(forKey: ws.id)?.stop()
        coordinator.teardownWorkspace(ws.id, park: true)
    }
}

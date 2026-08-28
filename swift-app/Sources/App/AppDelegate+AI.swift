// goty — see CLAUDE.md for the working principles.
import GhosttyKit
import AppKit

extension AppDelegate {

    // MARK: AI tasks (@ai)

    /// The live coordinator, rebuilt when the AI provider settings
    /// (base URL / model) change. Running tasks live in the coordinator
    /// they started with; both stay wired to onUpdate.
    func aiCoordinator() -> AITaskCoordinator {
        let p = AppPreferences.shared
        // The key is part of the token: changing only the API key must
        // rebuild the client too, or tasks keep firing 401s on the
        // stale key until restart (plan Task 8: prefs re-read per start).
        let key = Keychain.secret(for: "aiApiKey") ?? ""
        let token = p.aiBaseUrl + "\n" + p.aiModel + "\n" + key + "\n" + p.aiApiType
        if let box = aiCoordinatorBox, box.token == token { return box.coordinator }
        let client = OpenAICompatibleClient(
            baseUrl: p.aiBaseUrl,
            apiKey: key,
            model: p.aiModel,
            apiType: OpenAICompatibleClient.APIType(rawValue: p.aiApiType) ?? .openai)
        let coord = AITaskCoordinator(
            model: client,
            executorFor: { target in
                switch target.transport {
                case .local: return LocalExecutor()
                case .ssh(let host): return SSHExecutor(host: host)
                }
            })
        coord.onUpdate = { [weak self] task in
            DispatchQueue.main.async {
                guard let self, let key = self.activeAIPane[task.id] else {
                    if ProcessInfo.processInfo.environment["GOTY_AI_DEBUG"] == "1" {
                        FileHandle.standardError.write("AICARD drop: no activeAIPane for \(task.id)\n".data(using: .utf8)!)
                    }
                    return
                }
                let host = self.hostPool[key] as? PaneHost
                if ProcessInfo.processInfo.environment["GOTY_AI_DEBUG"] == "1" {
                    FileHandle.standardError.write("AICARD phase=\(task.phase) host=\(host != nil) frame=\(host?.currentAITaskCard?.frame ?? .zero)\n".data(using: .utf8)!)
                }
                host?.showAITask(task)
                // A task card showing clears stale ask cards on OTHER
                // panes (one AI surface at a time — tasks win).
                for other in self.hostPool.values where (other as? PaneHost) !== host {
                    (other as? PaneHost)?.hideAITaskIfInputMode()
                }
                if let host { self.wireAICard(host, task: task) }
            }
        }
        aiCoordinatorBox = (token, coord)
        return coord
    }

    func startAITask(host: PaneHost, text: String) {
        // A leftover ⌘⇧A card on this pane would freeze and block the
        // task render (the inputMode guard) — the "two panels" bug.
        host.hideAITaskIfInputMode()
        guard let target = host.coordinatorFeed?()
            ?? coordinator.aiTarget(for: host.hostKey) else { return }
        let context = AIContext(request: text, target: target,
                                visibleOutput: host.aiTail.snapshot, hostFacts: "")
        let coord = aiCoordinator()
        let id = coord.start(context: context)
        activeAIPane[id] = host.hostKey
        aiTaskOwner[id] = coord
        if ProcessInfo.processInfo.environment["GOTY_AI_DEBUG"] == "1" {
            FileHandle.standardError.write("AISTART id=\(id) mapped to pane=\(host.hostKey.pane)\n".data(using: .utf8)!)
        }
    }

    private func wireAICard(_ host: PaneHost, task: AITask) {
        guard let card = host.currentAITaskCard else { return }
        let id = task.id
        // Route to the coordinator that owns the task: a settings change
        // mid-task builds a new coordinator that doesn't know this id.
        let owner = aiTaskOwner[id] ?? aiCoordinator()
        card.onConfirm = { [weak owner] in owner?.confirm(taskId: id) }
        card.onEdit = { [weak owner] proposal in
            owner?.edit(taskId: id, to: proposal)
        }
        card.onCancel = { [weak owner] in
            owner?.cancel(taskId: id)
            host.hideAITask()
        }
        card.onContinue = { [weak owner] in owner?.continueBudget(taskId: id) }
        // Top-right close: always available; closing a still-running
        // agent cancels it first (cancel is inert on terminal phases).
        card.onClose = { [weak owner] in
            owner?.cancel(taskId: id)
            host.hideAITask()
        }
    }

    /// Local panes: the shared daemon, the user's login shell, the user's
    /// environment. Remote panes: the workspace's forwarded daemon and the
    /// remote login shell — never the Mac's environment.
    func paneDaemonTarget(wsId: UUID, command: String?) -> PaneDaemonTarget? {
        guard let store = coordinator.store,
              let ws = store.workspaces.first(where: { $0.id == wsId }) else { return nil }
        if !ws.isRemote {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let args = (command?.isEmpty == false) ? ["-l", "-c", "exec " + command!] : ["-l"]
            return PaneDaemonTarget(daemon: .shared, shell: shell, args: args,
                                    environment: UserShellEnv.asDictionary)
        }
        guard let link = remoteLinks[wsId], link.state == .ready,
              let daemon = link.daemon else { return nil }
        let args = (command?.isEmpty == false)
            ? ["-l", "-c", "exec " + command!] : ["-l"]
        return PaneDaemonTarget(daemon: daemon, shell: link.remoteShell, args: args,
                                environment: [:])
    }

    /// Agent session spawn shape: the ACP command via the user's real
    /// login environment (version managers), no ghostty surface.
    /// M1 is local-daemon only — SSH agent sessions are M2 (spec).
    func agentPaneTarget(wsId: UUID, launch: AgentManifests.ACPLaunch) -> PaneDaemonTarget? {
        guard let store = coordinator.store,
              let ws = store.workspaces.first(where: { $0.id == wsId }) else { return nil }
        guard !ws.isRemote else { return nil }
        return PaneDaemonTarget(daemon: .shared, shell: launch.command, args: launch.args,
                                environment: UserShellEnv.asDictionary)
    }

    func startRemoteLink(_ workspace: WorkspaceState) {
        guard let host = workspace.sshHost else { return }
        let link = RemoteDaemonLink(host: host)
        link.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                switch state {
                case .ready:
                    self.coordinator.workspaceConnected(workspace.id)
                    self.refresh()
                case .outdated:
                    // Old daemon instance still serving (fixed socket +
                    // singleton): panes work, agent logo/status don't.
                    // Restarting ends the remote sessions — the user
                    // decides; declining proceeds degraded (2026-08-24
                    // silent-remote-degradation root cause) and is
                    // REMEMBERED per host, so the prompt is one nag per
                    // daemon build, not one per launch.
                    if let capability = link.reportedCapability,
                       self.prefs.daemonUpgradeDeclined(key: workspace.name,
                                                        capability: capability) {
                        link.acceptOutdated()
                        break
                    }
                    let sessions = self.coordinator.store?.workspaces
                        .first(where: { $0.id == workspace.id })?.tabs.count ?? 0
                    if Dialog.confirm(
                        title: "Upgrade Goty daemon on \(workspace.name)?",
                        detail: "This server keeps running an older goty-sessiond — sessions "
                            + "survive GUI restarts, so it was never replaced. Agent logos and "
                            + "live status won't work until it's upgraded. Restarting it closes "
                            + "the \(sessions) session(s) currently running there.",
                        action: "Restart Daemon") {
                        link.upgradeDaemon()
                    } else {
                        self.prefs.declineDaemonUpgrade(key: workspace.name,
                                                        capability: link.reportedCapability ?? 0)
                        link.acceptOutdated()
                    }
                case .failed:
                    self.coordinator.workspaceDisconnected(workspace.id)
                case .connecting:
                    break
                }
            }
        }
        remoteLinks[workspace.id] = link
        link.start()
    }
}

// goty - see CLAUDE.md for the working principles.
import Foundation

/// The pi 0.8x dialect of the pi-mono family: immediate get_state
/// handshake (no protocol negotiation), ring-replay rendering through
/// the mapper (user echo on), history via get_messages, sessions in
/// PiSessionStore. The narrowest dialect — every omp-era capability
/// keeps the core's no-op default.
final class PiLegacySession: PiSession {
    override func appendSpawnArgs(_ args: inout [String], resume sessionId: String?) {
        // pi EXITS when --session names an id its store no longer
        // has ("No session found matching '…'" → EXITED → the
        // pane reported 进程已退出 forever). Only resume ids the
        // store can still find; a missing one boots fresh.
        if let sessionId, PiSessionStore.find(sessionId: sessionId) != nil {
            args += ["--session", sessionId]
        }
    }

    override func loadCommandsAfterHandshake() {
        request("get_commands") { [weak self] response in
            guard let self, response["success"] as? Bool == true else { return }
            // Response wraps the list: {"commands":[…]} (verified
            // live); a bare array is tolerated for forward compat.
            let raw = (response["data"] as? [String: Any])?["commands"]
                as? [[String: Any]]
                ?? (response["commands"] as? [[String: Any]])
                ?? []
            let commands = raw.compactMap { (item: [String: Any]) -> AgentSlashCommand? in
                guard let name = item["name"] as? String else { return nil }
                return AgentSlashCommand(
                    name: name,
                    description: item["description"] as? String,
                    inputHint: (item["input"] as? [String: Any])?["hint"] as? String)
            }
            self.adoptCommands(commands)
        }
    }

    override func sessionSummaries(
            _ completion: @escaping ([AgentSessionSummary]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return completion([]) }
            // Daemon-side store (capability 8): remote panes must read
            // THEIR host's ~/.pi, not the GUI's. Local fallback keeps
            // old daemons identical.
            if let (rows, _) = self.daemon.agentStoreSummaries(cwd: self.cwd, store: "pi") {
                completion(rows.map { $0.summary })
            } else {
                completion(PiSessionStore.summaries(cwd: self.cwd))
            }
        }
    }

    override func completeSessionLoad(_ completion: @escaping (Bool) -> Void) {
        request("get_messages") { [weak self] response in
            guard let self,
                  response["success"] as? Bool == true,
                  let data = response["data"] as? [String: Any],
                  let messages = data["messages"] as? [[String: Any]] else {
                completion(false)
                return
            }
            let replayMapper = PiFrameMapper()
            var events: [AgentSessionEvent] = []
            for message in messages {
                events += replayMapper.mapReplayedMessage(message)
            }
            if let assistant = messages.last(where: { $0["role"] as? String == "assistant" }),
               assistant["stopReason"] as? String == "error",
               let text = AgentSessionEvent.providerErrorText(from: assistant) {
                events.append(.error(text: text))
            }

            self.emit(events)
            completion(true)
        }
    }
}

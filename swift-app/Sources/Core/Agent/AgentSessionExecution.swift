// goty — see CLAUDE.md for the working principles.
import Foundation

/// Background-work / main-delivery boundary for agent adapters
/// (2026-09-14 concurrency spec). Blocking daemon calls (socket
/// connects, remote open attempts) must never sit on the main thread;
/// their RESULTS must never touch adapter state anywhere but the main
/// actor.
enum AgentSessionExecution {
    /// Run `work` on a user-initiated background queue, deliver its
    /// value on the main queue. No serial shared queue — separate
    /// panes connect concurrently.
    static func runOffMain<Value>(
        work: @escaping () -> Value,
        completion: @escaping (Value) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let value = work()
            DispatchQueue.main.async {
                completion(value)
            }
        }
    }
}

/// Generation fence for connection attempts (spec invariant 4): a
/// result from an obsolete connect/reconnect attempt must not install
/// a pane after shutdown or after a newer attempt started. Each
/// `open` and `invalidate` advances the generation; a completion whose
/// captured generation is no longer current routes to `onStale`
/// instead of `completion` (the caller closes the returned pane).
@MainActor
final class AgentConnectionGate {
    private var generation: UInt64 = 0

    func open<Value>(
        work: @escaping () -> Value,
        onStale: @escaping (Value) -> Void,
        completion: @escaping (Value) -> Void
    ) {
        generation &+= 1
        let candidate = generation
        AgentSessionExecution.runOffMain(work: work) { [weak self] value in
            guard let self, self.generation == candidate else {
                onStale(value)
                return
            }
            completion(value)
        }
    }

    func invalidate() {
        generation &+= 1
    }
}

// goty — see CLAUDE.md for the working principles.
import Foundation

/// Bare ndjson framing for dialects that are NOT JSON-RPC 2.0 —
/// claude's stream-json SDK mode and pi's rpc mode. Both directions are
/// one JSON object per line with their own id conventions inside the
/// payload (claude `request_id`/`response_id`, pi command `id`s), so the
/// channel stays transport-only: split, parse, route, and the adapter
/// owns every field.
///
/// Shares the invariants of JSONRPCChannel: lock-guarded splitter + echo
/// ring (the no-echo stty race window applies to every pane), completions
/// never fired inside the lock, and unparseable lines COUNTED — never
/// silently dropped.
final class LineChannel {
    /// Every parsed inbound frame, on the pane's reader thread.
    var onFrame: (([String: Any]) -> Void)?
    /// Non-JSON output lines (agent stderr merges into the pane). These
    /// are COUNTED always; the callback lets adapters surface death
    /// messages instead of losing them to the garbage guard.
    var onUnparseable: ((String) -> Void)?
    var onOutbound: (([UInt8]) -> Void)?

    private let lock = NSLock()
    private var recentOut: [String] = []
    private var splitter = NdjsonSplitter()
    private static let echoRing = 32

    /// Integrity accounting (probes/agenttest assert these).
    private(set) var framesRouted = 0
    private(set) var unparseableLines = 0

    /// `replay` is accepted for symmetry with JSONRPCChannel (ring
    /// reattach); unlike JSON-RPC there are no stale-response id
    /// collisions to suppress — every replayed frame routes normally and
    /// the adapter decides what history means.
    func feed(_ bytes: [UInt8], replay: Bool = false) {
        lock.lock()
        var frames: [[String: Any]] = []
        for line in splitter.feed(bytes) {
            if recentOut.contains(line) { continue }
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data),
                  let frame = json as? [String: Any] else {
                unparseableLines += 1
                onUnparseable?(line)
                continue
            }
            framesRouted += 1
            frames.append(frame)
        }
        lock.unlock()
        for frame in frames {
            onFrame?(frame)
        }
    }

    func send(_ frame: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: frame),
              let line = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        // Bare line, matching NdjsonSplitter's output shape — see
        // JSONRPCChannel.send for why the terminated form never matched.
        recentOut.append(line)
        if recentOut.count > Self.echoRing { recentOut.removeFirst(recentOut.count - Self.echoRing) }
        lock.unlock()
        onOutbound?(Array((line + "\n").utf8))
    }
}

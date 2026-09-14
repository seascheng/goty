// goty — see CLAUDE.md for the working principles.
import Foundation

/// Bare ndjson framing for dialects that are NOT JSON-RPC 2.0 —
/// claude's stream-json SDK mode and pi's rpc mode. Both directions are
/// one JSON object per line with their own id conventions inside the
/// payload (claude `request_id`/`response_id`, pi command `id`s), so the
/// channel stays transport-only: split, parse, route, and the adapter
/// owns every field.
///
/// Concurrency (2026-09-14 spec): the same execution contract as
/// JSONRPCChannel — `framingLock` guards only the splitter, `stateLock`
/// guards the echo ring and counters, JSON parsing runs off-lock on the
/// reader thread, and one `feed` builds a single ordered frame array
/// (each frame carrying its replay flag) delivered with ONE hop on the
/// configured callback queue (`nil` = synchronous, tests/probes).
/// Unparseable lines are COUNTED — never silently dropped — and
/// `onUnparseable` never fires under a lock.
final class LineChannel {
    typealias Parser = (Data) -> Any?

    /// Every parsed inbound frame. The Bool marks ring-replay frames:
    /// adapters must not drive TURN state (working/thinking) from
    /// history — only from live frames. Delivery happens on the
    /// configured callback queue, in wire order, replay flag intact.
    var onFrame: (([String: Any], _ replay: Bool) -> Void)?
    /// Non-JSON output lines (agent stderr merges into the pane). These
    /// are COUNTED always; the callback lets adapters surface death
    /// messages instead of losing them to the garbage guard.
    var onUnparseable: ((String) -> Void)?
    var onOutbound: (([UInt8]) -> Void)?

    private let callbackQueue: DispatchQueue?
    private let parser: Parser
    private let framingLock = NSLock()
    private let stateLock = NSLock()
    private var splitter = NdjsonSplitter()
    private var recentOut: [String] = []
    private static let echoRing = 32

    /// Integrity accounting (probes/agenttest assert these).
    private var _framesRouted = 0
    private var _unparseableLines = 0

    init(callbackQueue: DispatchQueue? = nil,
         parser: @escaping Parser = { try? JSONSerialization.jsonObject(with: $0) }) {
        self.callbackQueue = callbackQueue
        self.parser = parser
    }

    var framesRouted: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _framesRouted
    }

    var unparseableLines: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _unparseableLines
    }

    /// Ring-reattach replay: frames carry the replay flag (see
    /// onFrame) — history must not be mistaken for a live turn.
    func feed(_ bytes: [UInt8], replay: Bool = false) {
        // 1. Extract complete lines under the narrow framing lock only.
        framingLock.lock()
        let lines = splitter.feed(bytes)
        framingLock.unlock()

        // 2. Parse off-lock on the reader thread; echo ring + counters
        //    under the narrow state lock only.
        var frames: [(frame: [String: Any], replay: Bool)] = []
        var unparseable: [String] = []
        frames.reserveCapacity(lines.count)
        for line in lines {
            stateLock.lock()
            let echoed = recentOut.contains(line)
            stateLock.unlock()
            if echoed { continue }
            guard let data = line.data(using: .utf8),
                  let json = parser(data),
                  let frame = json as? [String: Any] else {
                stateLock.lock()
                _unparseableLines += 1
                stateLock.unlock()
                unparseable.append(line)
                continue
            }
            stateLock.lock()
            _framesRouted += 1
            stateLock.unlock()
            frames.append((frame, replay))
        }

        // 3. One queue hop for the whole batch, no lock held, wire order.
        guard !frames.isEmpty || !unparseable.isEmpty else { return }
        let work = { [self] in
            for line in unparseable { onUnparseable?(line) }
            for entry in frames { onFrame?(entry.frame, entry.replay) }
        }
        if let callbackQueue {
            callbackQueue.async(execute: work)
        } else {
            work()
        }
    }

    func send(_ frame: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: frame),
              let line = String(data: data, encoding: .utf8) else { return }
        stateLock.lock()
        // Bare line, matching NdjsonSplitter's output shape — see
        // JSONRPCChannel.send for why the terminated form never matched.
        recentOut.append(line)
        if recentOut.count > Self.echoRing { recentOut.removeFirst(recentOut.count - Self.echoRing) }
        stateLock.unlock()
        onOutbound?(Array((line + "\n").utf8))
    }
}

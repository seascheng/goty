// goty — see CLAUDE.md for the working principles.
import Foundation

/// JSON-RPC `error.message` carrier. String itself is not an Error
/// (SE-0192 removed the implicit conformance). LocalizedError exposes
/// the server's message ("thread not found: …") — without it Swift
/// prints "goty.RPCFailure error 0" and the real reason is lost.
enum RPCFailure: Error, LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

/// JSON-RPC 2.0 over ndjson for one agent pane — protocol-agnostic
/// (omp speaks ACP on it, codex speaks app-server). Inbound traffic is
/// loosely typed ([String: Any]) on purpose; the session adapter owns
/// the typed extraction. Outbound goes through onOutbound → PaneSession.sendInput.
///
/// Concurrency (2026-09-14 spec): `feed` runs on the pane's reader
/// thread; `request`/`notify`/`respond` run wherever the adapter calls
/// them. Two NARROW locks replace the old single one —
/// - `framingLock` guards only the splitter (line extraction);
/// - `stateLock` guards pending map, id counter, echo ring, counters.
/// JSON parsing happens under NO lock on the reader thread (a large
/// replay no longer blocks a concurrent `request`), and every callback
/// fires outside both locks — consumers may answer a server request
/// synchronously (respond → send → same lock) or chain follow-ups;
/// under a lock that is a guaranteed self-deadlock (codex hit it on
/// its first server request; 2026-08-29).
///
/// Delivery: each `feed` builds ONE ordered `Delivery` array (wire
/// order, callbacks NOT grouped by type) and hands it to the configured
/// `callbackQueue` in a single hop — production uses `.main`, so a
/// 200k-frame replay costs one main-queue dispatch, not one per line.
/// A nil queue delivers synchronously (tests/probes).
///
/// Echo filter: the no-echo stty runs inside the pty microseconds after
/// fork; anything we write before it lands can come back verbatim. The
/// last 32 outbound lines are ring-buffered and dropped on sight.
///
/// Replay mode: the daemon's ring replay (reattach to a live pane)
/// re-streams history containing stale responses to OLD requests. Those
/// carry the same small ids a fresh handshake is about to use —
/// completing a fresh pending entry from a stale replayed response would
/// bind wrong session ids. Replayed responses therefore never complete
/// pending requests; notifications and server→client requests still
/// route (transcript rebuild + permission revival).
final class JSONRPCChannel {
    typealias Parser = (Data) -> Any?

    /// One recognized wire message, in wire order. Completions carry
    /// their completion so a single ordered pass can fire everything.
    private enum Delivery {
        case unparseable(String)
        case notification(String, [String: Any])
        case request(Int, String, [String: Any])
        case replayRequest(Int, String, [String: Any])
        case orphan([String: Any])
        case completion(Result<[String: Any], RPCFailure>,
                        (Result<[String: Any], RPCFailure>) -> Void)
    }

    var onNotification: ((String, [String: Any]) -> Void)?
    /// Non-JSON output lines (agent stderr merges into the pane);
    /// counted always, surfaced for death-message diagnosis.
    var onUnparseable: ((String) -> Void)?
    /// server→client request (session/request_permission)
    var onRequest: ((Int, String, [String: Any]) -> Void)?
    var onOutbound: (([UInt8]) -> Void)?
    /// A replayed response nobody is waiting for — the ring re-streamed
    /// the handshake of the pane's FIRST client. Its result is the only
    /// place a reattaching adapter can re-learn the live ids (omp's
    /// sessionId from the original session/new, codex's thread_id from
    /// thread/start) without re-running a handshake against a process
    /// that already owns them.
    var onOrphanResult: (([String: Any]) -> Void)?
    /// A replayed client→server request (ring_input panes re-stream the
    /// user's own session/prompt wire). This is the ONLY record of the
    /// user's side of a conversation for a reattaching adapter — live ACP
    /// updates never echo prompts. Fires outside the lock, replay only.
    var onReplayRequest: ((Int, String, [String: Any]) -> Void)?

    private let callbackQueue: DispatchQueue?
    private let parser: Parser
    private let framingLock = NSLock()
    private let stateLock = NSLock()
    private var splitter = NdjsonSplitter()
    private var nextID = 1
    private var pending: [Int: (Result<[String: Any], RPCFailure>) -> Void] = [:]
    private var recentOut: [String] = []
    private static let echoRing = 32

    /// Integrity accounting (probes/agenttest assert these).
    private var _messagesRouted = 0
    private var _unparseableLines = 0

    init(callbackQueue: DispatchQueue? = nil,
         parser: @escaping Parser = { try? JSONSerialization.jsonObject(with: $0) }) {
        self.callbackQueue = callbackQueue
        self.parser = parser
    }

    var messagesRouted: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _messagesRouted
    }

    var unparseableLines: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _unparseableLines
    }

    var debugPendingCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pending.count
    }

    /// `replay`: consuming ring history — see the replay-mode notes above.
    /// ALL callbacks (completions, notifications, requests) fire OUTSIDE
    /// the locks on the configured callback queue, in wire order.
    func feed(_ bytes: [UInt8], replay: Bool = false) {
        // 1. Extract complete lines under the narrow framing lock only.
        framingLock.lock()
        let lines = splitter.feed(bytes)
        framingLock.unlock()

        // 2. Parse and classify off-lock, on the reader thread.
        var deliveries: [Delivery] = []
        deliveries.reserveCapacity(lines.count)
        for line in lines {
            stateLock.lock()
            let echoed = recentOut.contains(line)
            stateLock.unlock()
            if echoed { continue }
            guard let data = line.data(using: .utf8),
                  let json = parser(data),
                  let message = json as? [String: Any] else {
                stateLock.lock()
                _unparseableLines += 1
                stateLock.unlock()
                deliveries.append(.unparseable(line))
                continue
            }
            stateLock.lock()
            _messagesRouted += 1
            stateLock.unlock()
            if let method = message["method"] as? String {
                let params = message["params"] as? [String: Any] ?? [:]
                if let id = message["id"] as? Int {
                    // A server request replayed from the ring belongs to
                    // the DEAD process's id space — routing it to
                    // onRequest creates phantom permission cards whose
                    // answers respond() to the WRONG live request id.
                    if replay {
                        deliveries.append(.replayRequest(id, method, params))
                    } else {
                        deliveries.append(.request(id, method, params))
                    }
                } else {
                    deliveries.append(.notification(method, params))
                }
                continue
            }
            // A response. Replayed history never completes fresh requests —
            // it surfaces to onOrphanResult instead (live id re-capture).
            if replay {
                if let result = message["result"] as? [String: Any] {
                    deliveries.append(.orphan(result))
                }
                continue
            }
            stateLock.lock()
            let completion: ((Result<[String: Any], RPCFailure>) -> Void)?
            if let id = message["id"] as? Int {
                completion = pending.removeValue(forKey: id)
            } else {
                completion = nil
            }
            stateLock.unlock()
            guard let completion else {
                // Live traffic can also orphan a response — a request we
                // already timed out of. Same hook, same reason.
                if let result = message["result"] as? [String: Any] {
                    deliveries.append(.orphan(result))
                }
                continue
            }
            if let error = message["error"] as? [String: Any],
               let text = error["message"] as? String {
                deliveries.append(.completion(.failure(.message(text)), completion))
            } else if let result = message["result"] as? [String: Any] {
                deliveries.append(.completion(.success(result), completion))
            } else {
                deliveries.append(.completion(.success([:]), completion))
            }
        }
        deliver(deliveries)
    }

    /// 3-5. One queue hop for the whole batch, no lock held, wire order.
    private func deliver(_ deliveries: [Delivery]) {
        guard !deliveries.isEmpty else { return }
        let work = { [self] in
            for delivery in deliveries {
                switch delivery {
                case .unparseable(let line): onUnparseable?(line)
                case .notification(let method, let params): onNotification?(method, params)
                case .request(let id, let method, let params): onRequest?(id, method, params)
                case .replayRequest(let id, let method, let params): onReplayRequest?(id, method, params)
                case .orphan(let result): onOrphanResult?(result)
                case .completion(let result, let completion): completion(result)
                }
            }
        }
        if let callbackQueue {
            callbackQueue.async(execute: work)
        } else {
            work()
        }
    }

    /// Fail EVERY outstanding request exactly once (transport exit,
    /// disconnect, shutdown, or a new transport epoch) — atomically
    /// drain, then deliver outside the lock. Unlike closing the channel,
    /// this leaves the id space reusable for a reconnect.
    func failPending(reason: String) {
        stateLock.lock()
        let completions = Array(pending.values)
        pending.removeAll(keepingCapacity: true)
        stateLock.unlock()
        let failure = Result<[String: Any], RPCFailure>.failure(.message(reason))
        deliver(completions.map { .completion(failure, $0) })
    }

    @discardableResult
    func request(_ method: String, _ params: [String: Any],
                 completion: @escaping (Result<[String: Any], RPCFailure>) -> Void) -> Int {
        stateLock.lock()
        let id = nextID
        nextID += 1
        pending[id] = completion
        stateLock.unlock()
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        return id
    }

    func notify(_ method: String, _ params: [String: Any]) {
        send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    /// Answer a server→client request (permission outcome).
    func respond(id: Int, result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let line = String(data: data, encoding: .utf8) else { return }
        stateLock.lock()
        // Ring stores the BARE line — the same shape NdjsonSplitter
        // yields on the way in (terminator stripped, \r trimmed). The
        // ring used to store the "\n"-terminated wire form and never
        // matched a single echo (codex proved it: the echoed initialize
        // parsed as a server request, got answered, and the empty
        // response completed our own pending handshake).
        recentOut.append(line)
        if recentOut.count > Self.echoRing { recentOut.removeFirst(recentOut.count - Self.echoRing) }
        stateLock.unlock()
        onOutbound?(Array((line + "\n").utf8))
    }
}

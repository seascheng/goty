// goty — see CLAUDE.md for the working principles.
import Foundation

/// JSON-RPC `error.message` carrier. String itself is not an Error
/// (SE-0192 removed the implicit conformance).
enum RPCFailure: Error {
    case message(String)
}

/// JSON-RPC 2.0 over ndjson for one agent pane — protocol-agnostic
/// (omp speaks ACP on it, codex speaks app-server). Inbound traffic is
/// loosely typed ([String: Any]) on purpose; the session adapter owns
/// the typed extraction. Outbound goes through onOutbound → PaneSession.sendInput.
///
/// Concurrency: frames arrive on the pane's reader thread while requests
/// are sent from the main thread — all mutable state (pending map, ids,
/// echo ring, splitter) is lock-guarded, and request completions fire
/// OUTSIDE the lock (connect chains issue follow-up requests from inside
/// completions). `pending` is inserted BEFORE the request hits the wire,
/// so a fast response can never outrun its own registration.
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
    var onNotification: ((String, [String: Any]) -> Void)?
    /// Non-JSON output lines (agent stderr merges into the pane);
    /// counted always, surfaced for death-message diagnosis.
    var onUnparseable: ((String) -> Void)?
    /// server→client request (session/request_permission)
    var onRequest: ((Int, String, [String: Any]) -> Void)?
    var onOutbound: (([UInt8]) -> Void)?

    private let lock = NSLock()
    private var nextID = 1
    private var pending: [Int: (Result<[String: Any], RPCFailure>) -> Void] = [:]
    private var recentOut: [String] = []
    private var splitter = NdjsonSplitter()
    private static let echoRing = 32

    /// Integrity accounting (probes/agenttest assert these).
    private(set) var messagesRouted = 0
    private(set) var unparseableLines = 0

    /// `replay`: consuming ring history — see the replay-mode notes above.
    /// ALL callbacks (completions, notifications, requests) fire OUTSIDE
    /// the lock: a consumer may answer a server request synchronously
    /// (respond → send → same lock) or chain follow-ups — under the lock
    /// that is a guaranteed self-deadlock (codex hit it on its first
    /// server request; 2026-08-29).
    func feed(_ bytes: [UInt8], replay: Bool = false) {
        var fired: [(Result<[String: Any], RPCFailure>,
                     (Result<[String: Any], RPCFailure>) -> Void)] = []
        var routed: [(Int, String, [String: Any])] = []
        var notified: [(String, [String: Any])] = []
        var unparseable: [String] = []
        lock.lock()
        for line in splitter.feed(bytes) {
            if recentOut.contains(line) { continue }
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data),
                  let message = json as? [String: Any] else {
                unparseableLines += 1
                unparseable.append(line)
                continue
            }
            messagesRouted += 1
            if let method = message["method"] as? String {
                let params = message["params"] as? [String: Any] ?? [:]
                if let id = message["id"] as? Int {
                    routed.append((id, method, params))
                } else {
                    notified.append((method, params))
                }
                continue
            }
            // A response. Replayed history never completes fresh requests.
            guard !replay, let id = message["id"] as? Int,
                  let completion = pending.removeValue(forKey: id) else { continue }
            if let error = message["error"] as? [String: Any],
               let text = error["message"] as? String {
                fired.append((.failure(.message(text)), completion))
            } else if let result = message["result"] as? [String: Any] {
                fired.append((.success(result), completion))
            } else {
                fired.append((.success([:]), completion))
            }
        }
        lock.unlock()
        for line in unparseable { onUnparseable?(line) }
        for (method, params) in notified { onNotification?(method, params) }
        for (id, method, params) in routed { onRequest?(id, method, params) }
        for (result, completion) in fired { completion(result) }
    }

    @discardableResult
    func request(_ method: String, _ params: [String: Any],
                 completion: @escaping (Result<[String: Any], RPCFailure>) -> Void) -> Int {
        lock.lock()
        let id = nextID
        nextID += 1
        pending[id] = completion
        lock.unlock()
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
        lock.lock()
        // Ring stores the BARE line — the same shape NdjsonSplitter
        // yields on the way in (terminator stripped, \r trimmed). The
        // ring used to store the "\n"-terminated wire form and never
        // matched a single echo (codex proved it: the echoed initialize
        // parsed as a server request, got answered, and the empty
        // response completed our own pending handshake).
        recentOut.append(line)
        if recentOut.count > Self.echoRing { recentOut.removeFirst(recentOut.count - Self.echoRing) }
        lock.unlock()
        onOutbound?(Array((line + "\n").utf8))
    }
}

// goty — see CLAUDE.md for the working principles.
import Foundation
/// JSON-RPC `error.message` carrier. String itself is not an Error
/// (SE-0192 removed the implicit conformance).
enum ACPFailure: Error {
    case message(String)
}

/// JSON-RPC 2.0 over ndjson for one agent pane. Inbound traffic is
/// loosely typed ([String: Any]) on purpose: the M1 ACP subset is small
/// and the schema is still moving (v1/v2); AgentSession owns the typed
/// extraction. Outbound goes through onOutbound → PaneSession.sendInput.
///
/// Echo filter: the no-echo stty runs inside the pty microseconds after
/// fork; anything we write before it lands can come back verbatim. The
/// last 32 outbound lines are ring-buffered and dropped on sight.
final class ACPClient {
    var onNotification: ((String, [String: Any]) -> Void)?
    /// server→client request (session/request_permission)
    var onRequest: ((Int, String, [String: Any]) -> Void)?
    var onOutbound: (([UInt8]) -> Void)?

    private var nextID = 1
    private var pending: [Int: (Result<[String: Any], ACPFailure>) -> Void] = [:]
    private var recentOut: [String] = []
    private var splitter = NdjsonSplitter()
    private static let echoRing = 32

    func feed(_ bytes: [UInt8]) {
        for line in splitter.feed(bytes) {
            if recentOut.contains(line) { continue }
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data),
                  let message = json as? [String: Any] else { continue }
            route(message)
        }
    }

    private func route(_ message: [String: Any]) {
        if let method = message["method"] as? String {
            let params = message["params"] as? [String: Any] ?? [:]
            if let id = message["id"] as? Int {
                onRequest?(id, method, params)
            } else {
                onNotification?(method, params)
            }
            return
        }
        // A response: complete the pending request. An echo that somehow
        // passed the exact-match filter lands here without a pending id.
        guard let id = message["id"] as? Int, let completion = pending.removeValue(forKey: id)
        else { return }
        if let error = message["error"] as? [String: Any],
           let text = error["message"] as? String {
            completion(.failure(.message(text)))
        } else if let result = message["result"] as? [String: Any] {
            completion(.success(result))
        } else {
            completion(.success([:]))
        }
    }

    @discardableResult
    func request(_ method: String, _ params: [String: Any],
                 completion: @escaping (Result<[String: Any], ACPFailure>) -> Void) -> Int {
        let id = nextID
        nextID += 1
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        pending[id] = completion
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
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        let bytes = Array(line.utf8)
        recentOut.append(line)
        if recentOut.count > Self.echoRing { recentOut.removeFirst(recentOut.count - Self.echoRing) }
        onOutbound?(bytes)
    }
}

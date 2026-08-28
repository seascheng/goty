// goty — see CLAUDE.md for the working principles.
import Foundation

/// Hand-written M1 subset of the ACP content shapes (spec: Risk — ACP
/// v2 drift; we bind to v1 only, loosely, and ignore unknown fields).
struct ACPContent {
    let type: String
    let text: String?
    let path: String?

    init?(_ raw: [String: Any]) {
        guard let type = raw["type"] as? String else { return nil }
        self.type = type
        self.text = raw["text"] as? String
        self.path = raw["path"] as? String
    }
}

struct ACPPlanEntry {
    let content: String
    let priority: String?
    let status: String?

    init?(_ raw: [String: Any]) {
        guard let content = raw["content"] as? String else { return nil }
        self.content = content
        self.priority = raw["priority"] as? String
        self.status = raw["status"] as? String
    }
}

struct ACPOption {
    let optionId: String
    let name: String
    let kind: String?

    init?(raw: [String: Any]) {
        guard let optionId = raw["optionId"] as? String,
              let name = raw["name"] as? String else { return nil }
        self.optionId = optionId
        self.name = name
        self.kind = raw["kind"] as? String
    }
}

struct ACPPermissionPrompt {
    let requestID: Int
    let toolCallTitle: String?
    let options: [ACPOption]
}

/// One decoded inbound ACP event, already shaped for the UI layer.
/// `toolCallUpdate` is upsert-by-id on the JS side; `permissionRequested`
/// carries the raw JSON-RPC id so the answer routes back correctly.
enum AgentSessionEvent {
    case ready
    case messageChunk(String)
    case thoughtChunk(String)
    case toolCallUpdate(id: String, title: String?, kind: String?,
                        status: String?, content: [ACPContent])
    case plan([ACPPlanEntry])
    case permissionRequested(ACPPermissionPrompt)
    case turnEnded(stopReason: String?)
}

protocol AgentSessionDelegate: AnyObject {
    func session(_ session: AgentSession, didEmit events: [AgentSessionEvent])
    func sessionDidFail(_ session: AgentSession, reason: String)
}

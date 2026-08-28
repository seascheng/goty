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

/// One `session/set_config_option`-selectable knob (mode / model /
/// thinking …) as `session/new` and the set response return it.
struct ACPConfigChoice {
    let value: String
    let name: String
    let description: String?

    init?(raw: [String: Any]) {
        guard let value = raw["value"] as? String,
              let name = raw["name"] as? String else { return nil }
        self.value = value
        self.name = name
        self.description = raw["description"] as? String
    }
}

struct ACPConfigOption {
    let id: String
    let name: String
    let category: String?
    let currentValue: String?
    let options: [ACPConfigChoice]

    init?(raw: [String: Any]) {
        guard let id = raw["id"] as? String,
              let name = raw["name"] as? String else { return nil }
        self.id = id
        self.name = name
        self.category = raw["category"] as? String
        self.currentValue = raw["currentValue"] as? String
        self.options = (raw["options"] as? [[String: Any]] ?? [])
            .compactMap { ACPConfigChoice(raw: $0) }
    }

    static func list(_ raw: Any?) -> [ACPConfigOption] {
        (raw as? [[String: Any]] ?? []).compactMap { ACPConfigOption(raw: $0) }
    }
}

/// One agent slash command from `available_commands_update`. Invoked by
/// prompting with `/{name} …` — the plain prompt path, no extra RPC.
struct ACPSlashCommand {
    let name: String
    let description: String?
    let inputHint: String?

    init?(raw: [String: Any]) {
        guard let name = raw["name"] as? String else { return nil }
        self.name = name
        self.description = raw["description"] as? String
        self.inputHint = (raw["input"] as? [String: Any])?["hint"] as? String
    }

    static func list(_ raw: Any?) -> [ACPSlashCommand] {
        (raw as? [[String: Any]] ?? []).compactMap { ACPSlashCommand(raw: $0) }
    }
}

/// One persisted agent session from `session/list`.
struct ACPSessionSummary {
    let sessionId: String
    let cwd: String?
    let title: String?
    let updatedAt: String?
    let messageCount: Int?

    init?(raw: [String: Any]) {
        guard let sessionId = raw["sessionId"] as? String else { return nil }
        self.sessionId = sessionId
        self.cwd = raw["cwd"] as? String
        self.title = raw["title"] as? String
        self.updatedAt = raw["updatedAt"] as? String
        let meta = raw["_meta"] as? [String: Any]
        self.messageCount = meta?["messageCount"] as? Int
    }

    static func list(_ raw: Any?) -> [ACPSessionSummary] {
        (raw as? [[String: Any]] ?? []).compactMap { ACPSessionSummary(raw: $0) }
    }
}

/// One decoded inbound ACP event, already shaped for the UI layer.
/// `toolCallUpdate` is upsert-by-id on the JS side; `permissionRequested`
/// carries the raw JSON-RPC id so the answer routes back correctly.
/// `rawInput` is the ACP-spec raw call arguments; `oldText` is our
/// pre-write snapshot of the target file (edit-like calls, local panes)
/// so the UI can render a real diff.
enum AgentSessionEvent {
    case ready
    case messageChunk(String)
    case thoughtChunk(String)
    case toolCallUpdate(id: String, title: String?, kind: String?,
                        status: String?, content: [ACPContent],
                        rawInput: [String: Any]?, oldText: String?)
    case plan([ACPPlanEntry])
    case permissionRequested(ACPPermissionPrompt)
    case turnEnded(stopReason: String?)
    /// Full config knob list (session/new + every set_config_option OK).
    case configChanged([ACPConfigOption])
    /// Agent slash-command directory (available_commands_update).
    case commandsChanged([ACPSlashCommand])
    /// Token/cost meter (usage_update; omp carries size/used/cost).
    case usageUpdate(used: Int?, size: Int?, costAmount: Double?, costCurrency: String?)
}

protocol AgentSessionDelegate: AnyObject {
    func session(_ session: AgentSession, didEmit events: [AgentSessionEvent])
    func sessionDidFail(_ session: AgentSession, reason: String)
}

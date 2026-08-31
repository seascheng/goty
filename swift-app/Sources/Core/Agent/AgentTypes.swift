// goty — see CLAUDE.md for the working principles.
import Foundation

/// Hand-written M1 subset of the ACP content shapes (spec: Risk — ACP
/// v2 drift; we bind to v1 only, loosely, and ignore unknown fields).
struct AgentContent {
    let type: String
    let text: String?
    let path: String?

    init?(_ raw: [String: Any]) {
        guard let type = raw["type"] as? String else { return nil }
        self.type = type
        self.text = raw["text"] as? String
        self.path = raw["path"] as? String
    }

    /// Explicit memberwise: defining the failable wire init suppresses
    /// the synthesized one, and the normalizer synthesizes leaf items.
    init(type: String, text: String?, path: String?) {
        self.type = type
        self.text = text
        self.path = path
    }
}

extension AgentContent {
    /// Exact JS leaf shape (store.ts ToolContentSchema).
    var jsRepresentation: [String: Any] {
        ["type": type, "text": text ?? NSNull(), "path": path ?? NSNull()]
    }
}

struct AgentPlanEntry {
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

struct AgentPermissionOption {
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

    /// Explicit memberwise (failable wire init suppresses the
    /// synthesized one) — native adapters build options directly.
    init(optionId: String, name: String, kind: String?) {
        self.optionId = optionId
        self.name = name
        self.kind = kind
    }
}

struct AgentPermissionPrompt {
    /// Dialect's raw request id as a string (ACP Int ids stringify;
    /// claude control_request ids are strings natively).
    let requestID: String
    let toolCallTitle: String?
    let options: [AgentPermissionOption]

    /// The binary gate adapters synthesize when the wire protocol has no
    /// option list of its own (claude control_request, codex approval).
    static func allowOrReject(requestID: String, title: String?) -> AgentPermissionPrompt {
        AgentPermissionPrompt(requestID: requestID, toolCallTitle: title, options: [
            AgentPermissionOption(optionId: "allow_once", name: "允许", kind: "allow_once"),
            AgentPermissionOption(optionId: "reject_once", name: "拒绝", kind: "reject_once"),
        ])
    }
}

/// One `session/set_config_option`-selectable knob (mode / model /
/// thinking …) as `session/new` and the set response return it.
struct AgentConfigChoice {
    let value: String
    let name: String
    let description: String?

    /// Explicit memberwise — the failable wire init suppresses the
    /// synthesized one; native adapters build choices directly.
    init(value: String, name: String, description: String?) {
        self.value = value
        self.name = name
        self.description = description
    }

    init?(raw: [String: Any]) {
        guard let value = raw["value"] as? String,
              let name = raw["name"] as? String else { return nil }
        self.value = value
        self.name = name
        self.description = raw["description"] as? String
    }
}

struct AgentConfigOption {
    let id: String
    let name: String
    let category: String?
    let currentValue: String?
    let options: [AgentConfigChoice]

    init?(raw: [String: Any]) {
        guard let id = raw["id"] as? String,
              let name = raw["name"] as? String else { return nil }
        self.id = id
        self.name = name
        self.category = raw["category"] as? String
        self.currentValue = raw["currentValue"] as? String
        self.options = (raw["options"] as? [[String: Any]] ?? [])
            .compactMap { AgentConfigChoice(raw: $0) }
    }

    /// Explicit memberwise (failable wire init suppresses the
    /// synthesized one) — native adapters build options directly.
    init(id: String, name: String, category: String?,
         currentValue: String?, options: [AgentConfigChoice]) {
        self.id = id
        self.name = name
        self.category = category
        self.currentValue = currentValue
        self.options = options
    }

    static func list(_ raw: Any?) -> [AgentConfigOption] {
        (raw as? [[String: Any]] ?? []).compactMap { AgentConfigOption(raw: $0) }
    }
}

/// One agent slash command from `available_commands_update`. Invoked by
/// prompting with `/{name} …` — the plain prompt path, no extra RPC.
struct AgentSlashCommand {
    let name: String
    let description: String?
    let inputHint: String?

    init?(raw: [String: Any]) {
        guard let name = raw["name"] as? String else { return nil }
        self.name = name
        self.description = raw["description"] as? String
        self.inputHint = (raw["input"] as? [String: Any])?["hint"] as? String
    }

    /// Explicit memberwise (failable wire init suppresses the
    /// synthesized one) — native adapters build commands directly.
    init(name: String, description: String?, inputHint: String?) {
        self.name = name
        self.description = description
        self.inputHint = inputHint
    }
    static func list(_ raw: Any?) -> [AgentSlashCommand] {
        (raw as? [[String: Any]] ?? []).compactMap { AgentSlashCommand(raw: $0) }
    }
}

/// One persisted agent session from `session/list`.
struct AgentSessionSummary {
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

    /// Explicit memberwise: the failable wire init suppresses the
    /// synthesized one, and native adapters (claude/pi store readers)
    /// construct summaries directly.
    init(sessionId: String, cwd: String?, title: String?,
         updatedAt: String?, messageCount: Int?) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.title = title
        self.updatedAt = updatedAt
        self.messageCount = messageCount
    }

    static func list(_ raw: Any?) -> [AgentSessionSummary] {
        (raw as? [[String: Any]] ?? []).compactMap { AgentSessionSummary(raw: $0) }
    }
}

/// One decoded inbound ACP event, already shaped for the UI layer.
/// `toolCallUpdate` is upsert-by-id on the JS side; `permissionRequested`
/// carries the raw JSON-RPC id so the answer routes back correctly.
/// `rawInput` is the ACP-spec raw call arguments; `oldText` is our
/// pre-write snapshot of the target file (edit-like calls, local panes)
/// so the UI can render a real diff.
enum AgentSessionEvent {
    /// The agent process is spawned but its handshake has not completed
    /// (omp: initialize+session/new; claude: system/init; codex:
    /// thread/start; pi: get_state). The composer surfaces this as an
    /// explicit starting chip — a hung MCP server must read as
    /// "starting", never as silent nothing.
    case starting(agent: String)
    case ready
    /// One COMPLETE user message — always its own transcript block (the
    /// JS store fuses consecutive `userChunk`s; replaying two prompts
    /// that interrupted turns apart must not merge them into one bubble).
    case userMessage(String)
    /// `user_message_chunk` — a fragment of one user message; consecutive
    /// fragments fuse into a single bubble. Live turns echo locally
    /// instead, so this only fires on session/load replay.
    case userChunk(String)
    case messageChunk(String)
    case thoughtChunk(String)
    case toolCallUpdate(id: String, title: String?, kind: String?,
                        status: String?, content: [AgentContent],
                        /// Tool result: `rawOutput.content` leaves (omp
                        /// displayContent fallback). The old flat-only
                        /// reader dropped these — the resume content loss.
                        output: [AgentContent],
                        rawInput: [String: Any]?, oldText: String?)
    case plan([AgentPlanEntry])
    case permissionRequested(AgentPermissionPrompt)
    case turnEnded(stopReason: String?)
    /// The adapter replaced the provisional transcript (ring replay)
    /// with an authoritative rebuild (session/load) — the page must
    /// clear before the authoritative events land. Maps to the
    /// store's existing "clearTranscript".
    case transcriptReset
    /// Full config knob list (session/new + every set_config_option OK).
    case configChanged([AgentConfigOption])
    /// Agent slash-command directory (available_commands_update).
    case commandsChanged([AgentSlashCommand])
    /// Token/cost meter (usage_update; omp carries size/used/cost).
    /// input/output token splits are part of the display contract for
    /// future agents — nil segments hide in the composer statusbar.
    case usageUpdate(used: Int?, size: Int?, input: Int?, output: Int?,
                     costAmount: Double?, costCurrency: String?)
}

extension AgentSessionEvent {
    /// The exact JS event shape the web store consumes (store.ts
    /// IncomingEventSchema) — one mapping for the app, the probes and
    /// the tests; the hand copies here used to drift and lose fields.
    var jsRepresentation: [String: Any] {
        switch self {
        case .starting(let agent):
            return ["type": "starting", "agent": agent]
        case .ready:
            return ["type": "status", "text": "就绪"]
        case .userMessage(let text):
            return ["type": "userMessage", "text": text]
        case .userChunk(let text):
            return ["type": "userChunk", "text": text]
        case .messageChunk(let text):
            return ["type": "agentChunk", "text": text]
        case .thoughtChunk(let text):
            return ["type": "thoughtChunk", "text": text]
        case .toolCallUpdate(let id, let title, let kind, let status,
                             let content, let output, let rawInput, let oldText):
            return ["type": "toolCall",
                    "id": id,
                    "title": title ?? NSNull(),
                    "kind": kind ?? NSNull(),
                    "status": status ?? NSNull(),
                    "content": content.map { $0.jsRepresentation },
                    "output": output.map { $0.jsRepresentation },
                    "rawInput": rawInput ?? NSNull(),
                    "oldText": oldText ?? NSNull()]
        case .plan(let entries):
            return ["type": "plan", "entries": entries.map { entry in
                ["content": entry.content,
                 "priority": entry.priority ?? NSNull(),
                 "status": entry.status ?? NSNull()] as [String: Any]
            }]
        case .permissionRequested(let prompt):
            return ["type": "permission",
                    "requestID": prompt.requestID,
                    "toolCallTitle": prompt.toolCallTitle ?? NSNull(),
                    "options": prompt.options.map { option in
                        ["optionId": option.optionId,
                         "name": option.name,
                         "kind": option.kind ?? NSNull()] as [String: Any]
                    }]
        case .transcriptReset:
            return ["type": "clearTranscript"]
        case .turnEnded:
            return ["type": "turnEnded"]
        case .configChanged(let options):
            return ["type": "configOptions", "options": options.map { option in
                ["id": option.id, "name": option.name,
                 "category": option.category ?? NSNull(),
                 "currentValue": option.currentValue ?? NSNull(),
                 "options": option.options.map { choice in
                    ["value": choice.value, "name": choice.name,
                     "description": choice.description ?? NSNull()] as [String: Any]
                 }] as [String: Any]
            }]
        case .commandsChanged(let commands):
            return ["type": "commands", "commands": commands.map { command in
                ["name": command.name,
                 "description": command.description ?? NSNull(),
                 "inputHint": command.inputHint ?? NSNull()] as [String: Any]
            }]
        case .usageUpdate(let used, let size, let input, let output,
                          let costAmount, let costCurrency):
            return ["type": "usage", "used": used ?? NSNull(), "size": size ?? NSNull(),
                    "input": input ?? NSNull(), "output": output ?? NSNull(),
                    "costAmount": costAmount ?? NSNull(),
                    "costCurrency": costCurrency ?? NSNull()]
        }
    }
}

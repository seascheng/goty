// goty — see CLAUDE.md for the working principles.
import Foundation

/// One image riding a user message (paste/pick/drop in the composer).
/// `data` is bare base64 (no data: prefix) — the pi-mono RPC ImageContent
/// shape; claude/codex adapters translate from it. Byte-for-byte what
/// the webview clipboard reader produced.
struct AgentImage {
    let mimeType: String
    let data: String

    init?(_ raw: [String: Any]) {
        guard let mimeType = raw["mimeType"] as? String,
              let data = raw["data"] as? String else { return nil }
        self.mimeType = mimeType
        self.data = data
    }

    init(mimeType: String, data: String) {
        self.mimeType = mimeType
        self.data = data
    }

    /// pi-mono RPC `images` entry — {type:"image", mimeType, data}.
    var piWire: [String: Any] {
        ["type": "image", "mimeType": mimeType, "data": data]
    }
}

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
    /// Phase/group name (omp todoPhases carry tasks grouped per phase;
    /// flat ACP plans leave it nil).
    let priority: String?
    let status: String?

    init?(raw: [String: Any]) {
        guard let content = raw["content"] as? String else { return nil }
        self.content = content
        self.priority = raw["priority"] as? String
        self.status = raw["status"] as? String
    }

    /// Explicit memberwise: the failable wire init above suppresses the
    /// synthesized one, and native adapters (todoPhases → entries)
    /// build entries directly.
    init(content: String, priority: String? = nil, status: String? = nil) {
        self.content = content
        self.priority = priority
        self.status = status
    }
}

/// Live runtime telemetry from RPC `get_state`: the composer status
/// strip (context usage, throughput, queue depth) and the fast-mode
/// toggle read this. Everything optional — a harness that cannot
/// supply a piece hides that segment.
struct AgentRuntimeStatus: Equatable {
    var fastModeEnabled: Bool?
    var fastModeActive: Bool?
    var contextTokens: Int?
    var contextWindow: Int?
    var tokensPerSecond: Double?
    var queuedMessages: Int?
    var isCompacting: Bool?
    var isStreaming: Bool?
}

/// One background async-job row (agent extension report → daemon LIST).
/// `startTime` is epoch ms; elapsed time is the GUI's to tick.
struct AgentJobSnapshot: Equatable {
    let id: String
    let kind: String
    let status: String
    let label: String
    let startTime: Double?

    init(id: String, kind: String, status: String,
         label: String, startTime: Double?) {
        self.id = id
        self.kind = kind
        self.status = status
        self.label = label
        self.startTime = startTime
    }

    init?(raw: [String: Any]) {
        guard let id = raw["id"] as? String else { return nil }
        self.id = id
        self.kind = (raw["type"] as? String) ?? (raw["kind"] as? String) ?? "bash"
        self.status = (raw["status"] as? String) ?? "running"
        self.label = (raw["label"] as? String) ?? ""
        self.startTime = raw["startTime"] as? Double
    }
}

/// One subagent roster update (RPC subagent_lifecycle/progress frames).
struct AgentSubagentUpdate: Equatable {
    let id: String
    let state: String?
    let detail: String?
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
    /// RPC extension dialog method behind this prompt
    /// ("select"/"confirm"/"input"/"editor"); nil = an ordinary
    /// option-list permission card.
    var dialog: String? = nil
    var placeholder: String? = nil
    var defaultValue: String? = nil

    init(requestID: String, toolCallTitle: String?,
         options: [AgentPermissionOption],
         dialog: String? = nil, placeholder: String? = nil,
         defaultValue: String? = nil) {
        self.requestID = requestID
        self.toolCallTitle = toolCallTitle
        self.options = options
        self.dialog = dialog
        self.placeholder = placeholder
        self.defaultValue = defaultValue
    }

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
    /// Provenance label for the row (a model's provider — e.g.
    /// "openrouter" in "openrouter/glm-4.7"): distinguishes same-name
    /// models across providers in the picker.
    let source: String?

    /// Explicit memberwise — the failable wire init suppresses the
    /// synthesized one; native adapters build choices directly.
    init(value: String, name: String, description: String?, source: String? = nil) {
        self.value = value
        self.name = name
        self.description = description
        self.source = source
    }

    init?(raw: [String: Any]) {
        guard let value = raw["value"] as? String,
              let name = raw["name"] as? String else { return nil }
        self.value = value
        self.name = name
        self.description = raw["description"] as? String
        self.source = raw["source"] as? String
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
    /// The model switched content blocks (wire contentIndex changed):
    /// render everything after this as a NEW block, in true stream
    /// order — no inference, no merging across it. Faithful-display
    /// contract (2026-09-01): the transcript mirrors the model's
    /// actual output structure, not a UI-side fusion of it.
    case chunkBoundary
    /// The authoritative history landed TRUNCATED (tail-first load):
    /// true = older entries exist and loadOlderHistory can fetch them.
    case historyTruncated(Bool)
    /// Older history, to be PREPENDED before the current blocks (the
    /// seam is a turn boundary — assembly invariants hold on both
    /// sides). Empty array = no more history.
    case transcriptPrepend(events: [AgentSessionEvent])
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
    /// Provider/model failure recorded by omp on the assistant message.
    /// The web store renders this in the composer error chip.
    case error(text: String)
    /// omp auto-retry schedule (auto_retry_start): attempt N of M with
    /// a delayMs backoff. The composer renders a live countdown; the
    /// turn keeps working until auto_retry_end resolves it.
    case retryScheduled(attempt: Int, maxAttempts: Int, delayMs: Int,
                          errorText: String?)

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
    /// Live runtime telemetry (get_state): context window usage,
    /// throughput, queue depth, fast-mode flags, compaction.
    case runtimeStatus(AgentRuntimeStatus)
    /// Transient status line (extension notify, notice/irc events).
    case notice(String)
    /// Transient system chatter (info-level notices: xd:// device
    /// mount/unmount on model switches). The page flashes it briefly
    /// instead of parking it in the transcript — the transcript stays
    /// conversation-shaped.
    case statusFlash(String)
    /// Live session title (omp session_info_update — /rename, omp's
    /// post-turn auto-naming): the composer's session name and the
    /// hosting tab follow it immediately, without a store re-list.
    case sessionTitle(String)
    /// Background async-job rows (daemon LIST poll → pane host).
    case backgroundJobs([AgentJobSnapshot])
    /// Subagent roster delta (subagent_lifecycle/progress frames).
    case subagentUpdate(AgentSubagentUpdate)
    /// A transcript block's session-entry id landed (branch anchor):
    /// `role` is "user" or "agent"; the store stamps the newest block
    /// of that role so 分支 buttons have something to target.
    case entryMark(role: String, entryId: String)
    /// The agent asked the host to open a URL (RPC login flows) — the
    /// HOST consumes it (NSWorkspace), never the page.
    case openURL(String)
    /// Session stats payload (get_session_stats) for the stats dialog.
    case sessionStats([String: Any])
}

extension AgentSessionEvent {
    /// omp prefixes provider failures with the HTTP status before a JSON
    /// payload (for example, `429 {"error":{"message":"..."}}`).
    /// Prefer the provider's human message while preserving a raw fallback.
    static func providerErrorText(from message: [String: Any]) -> String? {
        guard let raw = message["errorMessage"] as? String else { return nil }
        return providerErrorText(raw: raw)
    }

    /// Extract the human message from a raw provider error payload
    /// (`"429 {"type":"error","error":{...}}"` → `error.message`,
    /// tidied of the `[code]` prefix and `[requestId]` tail).
    static func providerErrorText(raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        guard let start = raw.firstIndex(of: "{"),
              let data = raw[start...].data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let text = error["message"] as? String,
              !text.isEmpty else {
            return raw
        }
        return tidyProviderMessage(text)
    }

    /// omp wraps the human message in bracketed tokens:
    /// `[1308][Usage limit reached for 5 hour. Your limit will reset
    /// at 2026-09-01 19:37:34][20260901172912…]` — the code prefix and
    /// the trailing request-id tail are noise; the clean message is
    /// what the UI must show (the reset time is the critical fact).
    static func tidyProviderMessage(_ message: String) -> String {
        var m = message
        // Drop a trailing bracketed request id (long hex token).
        if m.hasSuffix("]"),
           let open = m.lastIndex(of: "["),
           open > m.startIndex {
            let tail = m[m.index(after: open)...].dropLast()
            if tail.count > 16, tail.allSatisfy({ $0.isHexDigit }) {
                m = String(m[..<open])
            }
        }
        // Drop a leading [code] token (short numeric bracket).
        if m.hasPrefix("["),
           let close = m.firstIndex(of: "]"),
           close > m.startIndex {
            let code = m[m.index(after: m.startIndex)..<close]
            if !code.isEmpty, code.allSatisfy({ $0.isNumber }) {
                m = String(m[m.index(after: close)...])
            }
        }
        // Drop the brackets wrapping the message itself ([text] → text).
        if m.hasPrefix("["), m.hasSuffix("]") {
            m = String(m.dropFirst().dropLast())
        }
        return m
    }

    /// The exact JS event shape the web store consumes (store.ts
    /// the tests; the hand copies here used to drift and lose fields.
    var jsRepresentation: [String: Any] {
        switch self {
        case .starting(let agent):
            return ["type": "starting", "agent": agent]
        case .ready:
            // Session-lifecycle signal, NOT transcript content: "就绪"
            // as a notice block accumulated once per load (no reset on
            // bare gate releases) — readiness shows through state
            // affordances (starting chip gone, composer enabled).
            return ["type": "ready"]
        case .statusFlash(let text):
            return ["type": "statusFlash", "text": text]
        case .userMessage(let text):
            return ["type": "userMessage", "text": text]
        case .userChunk(let text):
            return ["type": "userChunk", "text": text]
        case .messageChunk(let text):
            return ["type": "agentChunk", "text": text]
        case .thoughtChunk(let text):
            return ["type": "thoughtChunk", "text": text]
        case .chunkBoundary:
            return ["type": "chunkBoundary"]
        case .historyTruncated(let truncated):
            return ["type": "historyTruncated", "truncated": truncated]
        case .transcriptPrepend(let events):
            return ["type": "transcriptPrepend",
                    "events": events.map { $0.jsRepresentation }]
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
                    "dialog": prompt.dialog ?? NSNull(),
                    "placeholder": prompt.placeholder ?? NSNull(),
                    "defaultValue": prompt.defaultValue ?? NSNull(),
                    "options": prompt.options.map { option in
                        ["optionId": option.optionId,
                         "name": option.name,
                         "kind": option.kind ?? NSNull()] as [String: Any]
                    }]
        case .transcriptReset:
            return ["type": "clearTranscript"]
        case .turnEnded:
            return ["type": "turnEnded"]
        case .error(let text):
            return ["type": "error", "text": text]
        case .retryScheduled(let attempt, let maxAttempts, let delayMs,
                              let errorText):
            return ["type": "retryScheduled",
                    "attempt": attempt, "maxAttempts": maxAttempts,
                    "delayMs": delayMs,
                    "errorText": errorText ?? NSNull()]

        case .configChanged(let options):
            return ["type": "configOptions", "options": options.map { option in
                ["id": option.id, "name": option.name,
                 "category": option.category ?? NSNull(),
                 "currentValue": option.currentValue ?? NSNull(),
                 "options": option.options.map { choice in
                    ["value": choice.value, "name": choice.name,
                     "description": choice.description ?? NSNull(),
                     "source": choice.source ?? NSNull()] as [String: Any]
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
        case .runtimeStatus(let s):
            return ["type": "runtimeStatus",
                    "fastEnabled": s.fastModeEnabled ?? NSNull(),
                    "fastActive": s.fastModeActive ?? NSNull(),
                    "contextTokens": s.contextTokens ?? NSNull(),
                    "contextWindow": s.contextWindow ?? NSNull(),
                    "tokensPerSecond": s.tokensPerSecond ?? NSNull(),
                    "queued": s.queuedMessages ?? NSNull(),
                    "compacting": s.isCompacting ?? NSNull(),
                    "streaming": s.isStreaming ?? NSNull()] as [String: Any]
        case .notice(let text):
            return ["type": "status", "text": text]
        case .sessionTitle(let title):
            return ["type": "sessionTitle", "title": title]
        case .backgroundJobs(let jobs):
            return ["type": "jobs", "jobs": jobs.map { job in
                ["id": job.id, "kind": job.kind, "status": job.status,
                 "label": job.label, "startTime": job.startTime ?? NSNull()] as [String: Any]
            }]
        case .subagentUpdate(let update):
            return ["type": "subagent", "id": update.id,
                    "state": update.state ?? NSNull(),
                    "detail": update.detail ?? NSNull()]
        case .entryMark(let role, let entryId):
            return ["type": "entryMark", "role": role, "entryId": entryId]
        case .openURL(let url):
            return ["type": "openURL", "url": url]
        case .sessionStats(let stats):
            return ["type": "stats", "stats": stats]
        }
    }
}

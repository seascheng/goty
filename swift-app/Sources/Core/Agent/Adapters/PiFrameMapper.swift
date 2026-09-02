// goty — see CLAUDE.md for the working principles.
import Foundation

/// pi rpc events → AgentSessionEvent. Shapes pinned by
/// swift-app/tools/fixtures/pi-rpc.jsonl + pi-resume.jsonl (pi 0.84.3,
/// recorded 2026-08-29). Live turns stream `message_update` deltas
/// (text/thinking) and carry tool calls as content blocks; history
/// (get_messages) returns whole messages — the mapper has a replay
/// entry point that emits full texts instead of deltas.
///
/// Live user echo: pi echoes our prompt back as a user message; the
/// composer already shows it, so live mapping suppresses role=user and
///
/// omp speaks the same pi-mono vocabulary with additions handled here:
/// `tool_execution_start/update/end` (omp streams tool lifecycle as
/// frames; pi carries tools as content blocks), `agent_end` as the
/// terminal frame when `terminalOnAgentEnd` (pi uses agent_settled), and
/// `available_commands_update`. Probed live on omp 18.0.10 (2026-08-31):
/// shapes in /tmp/goty_rpc_probe3.py output.
final class PiFrameMapper {
    private var pendingTools: [String: (name: String, arguments: [String: Any]?)] = [:]
    private var completedTools: Set<String> = []
    /// Content block the current delta run extends (wire contentIndex);
    /// nil until the first delta of a message.
    private var lastContentIndex: Int?
    /// Last failed auto-retry's full error text (omp auto_retry_end
    /// success:false). A terminal agent_end right after must not
    /// replace it with the bare provider message — the retry story
    /// ("Retry failed … Original error: 429 …") is the useful one.
    private var lastRetryFailure: String?
    /// omp: agent_end terminates the run (isTerminal false = a mid-run
    /// boundary that must not close streaming rows). pi: agent_settled is
    /// the terminal frame instead.
    private let terminalOnAgentEnd: Bool
    /// During attach replay the mapper emits the user echo it otherwise
    /// suppresses live (the composer shows live prompts itself; a
    /// reattached page must rebuild the user side from the ring).
    var replaying = false

    init(terminalOnAgentEnd: Bool = false) {
        self.terminalOnAgentEnd = terminalOnAgentEnd
    }

    /// Integrity accounting (agenttest asserts these).
    private(set) var eventsRouted = 0
    private(set) var framesIgnored = 0

    /// One live notification frame (agent_start, message_update, …).
    func map(_ frame: [String: Any]) -> [AgentSessionEvent] {
        eventsRouted += 1
        guard let type = frame["type"] as? String else {
            framesIgnored += 1
            return []
        }
        switch type {
        case "message_update":
            return mapDelta(frame)
        case "message_end":
            return mapMessageEnd(frame)
        case "turn_end":
            return mapToolResults(frame["toolResults"])
        case "agent_settled":
            return [.turnEnded(stopReason: nil)]
        case "agent_end":
            // A non-terminal agent_end is a turn boundary inside a
            // continuing run (omp auto-retry); it must not finalize
            // streaming rows.
            if terminalOnAgentEnd, frame["isTerminal"] as? Bool != false {
                let assistant = (frame["messages"] as? [[String: Any]])?
                    .last(where: { $0["role"] as? String == "assistant" })
                let stop = (assistant?["stopReason"] as? String)
                    ?? (frame["stopReason"] as? String)
                var events: [AgentSessionEvent] = [.turnEnded(stopReason: stop)]
                if stop == "error", let assistant,
                   lastRetryFailure == nil,
                   let text = AgentSessionEvent.providerErrorText(from: assistant) {
                    events.append(.error(text: text))
                }
                lastRetryFailure = nil
                return events
            }
            framesIgnored += 1
            return []
        case "auto_retry_start":
            // omp backs off and retries provider failures (429 etc.)
            // — the turn is NOT over. The preceding agent_end was a
            // non-terminal boundary; leave working state untouched,
            // but carry the schedule so the composer can show a
            // countdown instead of a bare spinner (TUI parity).
            let schedule = (frame["attempt"] as? Int ?? 0,
                            frame["maxAttempts"] as? Int ?? 0,
                            frame["delayMs"] as? Int ?? 0)
            // The retry's own payload carries the ORIGINAL provider
            // error — surface its human message with the countdown so
            // the user sees what the agent is waiting out.
            let rawError = frame["errorMessage"] as? String
            let errorText = rawError.flatMap(AgentSessionEvent.providerErrorText(raw:))
            return [.retryScheduled(attempt: schedule.0,
                                    maxAttempts: schedule.1,
                                    delayMs: schedule.2,
                                    errorText: errorText)]
        case "auto_retry_end":
            guard frame["success"] as? Bool == false else { return [] }
            let text = Self.readableRetryFailure(frame)
                ?? (frame["errorMessage"] as? String)
                ?? "Auto-retry failed"
            lastRetryFailure = text
            return [.error(text: text)]
        case "agent_start", "turn_start", "message_start",
             "extension_ui_request":
            // Deltas and message_end carry the content; extension UI
            // requests (setStatus/setWidget; omp approvals ride a select
            // method not yet surfaced) count but do not render in v1.
            framesIgnored += 1
            return []
        case "available_commands_update":
            let list = AgentSlashCommand.list(frame["commands"])
            return list.isEmpty ? [] : [.commandsChanged(list)]
        case "tool_execution_start":
            return mapToolExecutionStart(frame)
        case "tool_execution_update":
            return mapToolExecutionUpdate(frame)
        case "tool_execution_end":
            return mapToolExecutionEnd(frame)
        case "notice":
            let text = (frame["message"] as? String)
                ?? (frame["text"] as? String) ?? ""
            guard !text.isEmpty else { return [] }
            // Info-level DEVICE chatter (source-tagged by omp: xdev
            // mount lists, the vision auto-mount explanation) rides the
            // transient flash chip — every model switch emits a pair,
            // and the transcript must stay conversation-shaped.
            // warning/error notices stay transcript lines.
            let level = (frame["level"] as? String) ?? "info"
            let source = frame["source"] as? String
                ?? frame["category"] as? String
            if level == "info", let source,
               source == "xdev" || source == "vision" {
                return [.statusFlash(text)]
            }
            return [.notice(text)]
        case "session_info_update":
            // /rename and omp's own retitle: the live title event. The
            // store head carries it too, but the frame lands the tab +
            // composer updates in the same tick as the rename.
            guard let title = frame["title"] as? String, !title.isEmpty else {
                return []
            }
            return [.sessionTitle(title)]
        case "command_output":
            // Builtin slash-command stdout (/compact, /stats, /models…):
            // omp answers the prompt with agentInvoked:false and reports
            // the run's text here — the ONLY feedback a command gives
            // (probed 18.0.11: "Compaction failed: Nothing to compact").
            // Dropped frames made /compact a silent no-op in the GUI.
            let text = (frame["text"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? [] : [.notice(text)]
        case "goal_updated":
            let goal = (frame["goal"] as? String)
                ?? (frame["message"] as? String) ?? ""
            return goal.isEmpty ? [] : [.notice("🎯 " + goal)]
        case "irc_message":
            let from = (frame["from"] as? String) ?? (frame["sender"] as? String) ?? "?"
            let text = (frame["message"] as? String) ?? (frame["text"] as? String) ?? ""
            return text.isEmpty ? [] : [.notice("⟵ hub \(from): \(text)")]
        case "subagent_lifecycle", "subagent_progress":
            return mapSubagent(frame, lifecycle: type == "subagent_lifecycle")
        default:
            framesIgnored += 1
            return []
        }
    }
    /// omp's finalError is `"Provider requested 1800000ms wait, exceeds
    /// retry.maxDelayMs (300000ms). Original error: 429 {json}"` — the
    /// key facts (limit window, reset time) sit inside the JSON. Swap
    /// the raw payload for its human `error.message` so the failure
    /// reads in one glance.
    static func readableRetryFailure(_ frame: [String: Any]) -> String? {
        guard let raw = frame["finalError"] as? String, !raw.isEmpty else {
            return nil
        }
        let marker = "Original error: "
        guard let range = raw.range(of: marker) else { return raw }
        let original = String(raw[range.upperBound...])
        guard let readable = AgentSessionEvent.providerErrorText(raw: original) else {
            return raw
        }
        return String(raw[..<range.lowerBound]) + marker + readable
    }

    /// History replay: whole PiAgentMessage records from get_messages.
    func mapReplayedMessage(_ message: [String: Any]) -> [AgentSessionEvent] {
        eventsRouted += 1
        let role = message["role"] as? String ?? ""
        let content = message["content"] as? [[String: Any]] ?? []
        var events: [AgentSessionEvent] = []
        switch role {
        case "user", "custom":
            let text = content.compactMap { $0["text"] as? String }.joined()
            if !text.isEmpty { events.append(.userMessage(text)) }
        case "assistant":
            for block in content {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String, !text.isEmpty {
                        events.append(.messageChunk(text))
                    }
                case "thinking":
                    if let text = block["thinking"] as? String, !text.isEmpty {
                        events.append(.thoughtChunk(text))
                    }
                case "toolCall":
                    events += toolCallStarted(block)
                default:
                    break
                }
            }
        case "toolResult":
            events += toolResultCompleted(message)
        default:
            framesIgnored += 1
        }
        return events
    }

    // MARK: - live pieces



    private func mapDelta(_ frame: [String: Any]) -> [AgentSessionEvent] {
        guard let event = frame["assistantMessageEvent"] as? [String: Any],
              let kind = event["type"] as? String else { return [] }
        switch kind {
        case "text_delta", "thinking_delta":
            guard let delta = event["delta"] as? String, !delta.isEmpty else {
                return []
            }
            // Faithful routing: the wire's contentIndex says which
            // content block this delta extends. A change = new block —
            // the UI renders stream order verbatim instead of merging
            // same-kind runs across intervening blocks.
            let index = event["contentIndex"] as? Int
            var events: [AgentSessionEvent] = []
            if index != lastContentIndex {
                lastContentIndex = index
                events.append(.chunkBoundary)
            }
            events.append(kind == "text_delta" ? .messageChunk(delta)
                                               : .thoughtChunk(delta))
            return events
        default:
            break // start/end markers — boundaries, not content
        }
        return []
    }

    private func mapMessageEnd(_ frame: [String: Any]) -> [AgentSessionEvent] {
        lastContentIndex = nil
        guard let message = frame["message"] as? [String: Any] else { return [] }
        let role = message["role"] as? String ?? ""
        switch role {
        case "user":
            // Live echo suppressed (the composer shows it); replay emits
            // it — a reattached page rebuilds the user side from the ring.
            if replaying {
                let text = (message["content"] as? [[String: Any]] ?? [])
                    .compactMap { $0["text"] as? String }.joined()
                var events: [AgentSessionEvent] = []
                if !text.isEmpty { events.append(.userMessage(text)) }
                if let entryId = message["id"] as? String {
                    events.append(.entryMark(role: "user", entryId: entryId))
                }
                return events
            }
            return []
        case "toolResult":
            return toolResultCompleted(message)
        case "assistant":
            // Text arrived via deltas; toolCall blocks start their cards.
            var events: [AgentSessionEvent] = []
            for block in message["content"] as? [[String: Any]] ?? []
                where block["type"] as? String == "toolCall" {
                events += toolCallStarted(block)
            }
            if message["stopReason"] as? String == "error",
               let text = AgentSessionEvent.providerErrorText(from: message) {
                events.append(.error(text: text))
            }

            if let entryId = message["id"] as? String {
                events.append(.entryMark(role: "agent", entryId: entryId))
            }
            return events
        default:
            return []
        }
    }

    // MARK: - omp tool_execution frames

    private func mapToolExecutionStart(_ frame: [String: Any]) -> [AgentSessionEvent] {
        guard let id = frame["toolCallId"] as? String,
              let name = frame["toolName"] as? String else { return [] }
        let arguments = frame["args"] as? [String: Any]
        pendingTools[id] = (name, arguments)
        let title = (frame["intent"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
        return [.toolCallUpdate(id: id, title: title,
                                kind: PiFrameMapper.toolKind(name),
                                status: "in_progress",
                                content: PiFrameMapper.headline(name: name, arguments: arguments),
                                output: [], rawInput: arguments, oldText: nil)]
    }

    private func mapToolExecutionUpdate(_ frame: [String: Any]) -> [AgentSessionEvent] {
        guard let id = frame["toolCallId"] as? String,
              let name = frame["toolName"] as? String,
              let partial = frame["partialResult"] as? [String: Any] else { return [] }
        let arguments = frame["args"] as? [String: Any]
        if pendingTools[id] == nil { pendingTools[id] = (name, arguments) }
        return [.toolCallUpdate(
            id: id, title: name,
            kind: PiFrameMapper.toolKind(name),
            status: "in_progress",
            content: PiFrameMapper.headline(name: name, arguments: arguments),
            output: PiFrameMapper.resultContent(partial["content"]),
            rawInput: arguments, oldText: nil)]
    }

    private func mapToolExecutionEnd(_ frame: [String: Any]) -> [AgentSessionEvent] {
        guard let id = frame["toolCallId"] as? String else { return [] }
        guard !completedTools.contains(id) else { return [] }
        completedTools.insert(id)
        let pending = pendingTools.removeValue(forKey: id)
        let name = frame["toolName"] as? String ?? pending?.name
        let isError = frame["isError"] as? Bool ?? false
        let result = frame["result"] as? [String: Any]
        return [.toolCallUpdate(
            id: id, title: name,
            kind: pending.map { PiFrameMapper.toolKind($0.name) },
            status: isError ? "failed" : "completed",
            content: (PiFrameMapper.diffBlock(from: result).map { [$0] } ?? [])
                + (pending.map { PiFrameMapper.headline(name: $0.name, arguments: $0.arguments) } ?? []),
            output: PiFrameMapper.resultContent(result?["content"]),
            rawInput: pending?.arguments, oldText: nil)]
    }


    private func mapToolResults(_ raw: Any?) -> [AgentSessionEvent] {
        guard let results = raw as? [[String: Any]] else { return [] }
        return results.flatMap { toolResultCompleted($0) }
    }

    // MARK: - tool shaping


    /// subagent_lifecycle/progress — shapes not pinned by fixtures, so
    /// every field is defensively extracted; a frame that names no
    /// agent id drops.
    private func mapSubagent(_ frame: [String: Any], lifecycle: Bool) -> [AgentSessionEvent] {
        guard let id = (frame["subagentId"] as? String)
            ?? (frame["agentId"] as? String)
            ?? (frame["id"] as? String) else { return [] }
        if lifecycle {
            let state = (frame["state"] as? String)
                ?? (frame["status"] as? String)
                ?? (frame["phase"] as? String)
            let detail = (frame["label"] as? String)
                ?? (frame["name"] as? String)
                ?? (frame["event"] as? String)
            return [.subagentUpdate(AgentSubagentUpdate(id: id, state: state, detail: detail))]
        }
        let detail = (frame["progress"] as? String)
            ?? (frame["message"] as? String)
            ?? (frame["detail"] as? String)
        return [.subagentUpdate(AgentSubagentUpdate(id: id, state: nil, detail: detail))]
    }
    private func toolCallStarted(_ block: [String: Any]) -> [AgentSessionEvent] {
        guard let id = block["id"] as? String,
              let name = block["name"] as? String else { return [] }
        let arguments = block["arguments"] as? [String: Any]
        pendingTools[id] = (name, arguments)
        let summary = PiFrameMapper.headline(name: name, arguments: arguments)
        return [.toolCallUpdate(id: id, title: name,
                                kind: PiFrameMapper.toolKind(name),
                                status: "in_progress",
                                content: summary, output: [],
                                rawInput: arguments, oldText: nil)]
    }

    private func toolResultCompleted(_ message: [String: Any]) -> [AgentSessionEvent] {
        guard let callId = message["toolCallId"] as? String else { return [] }
        guard !completedTools.contains(callId) else { return [] }
        completedTools.insert(callId)
        let pending = pendingTools.removeValue(forKey: callId)
        let name = message["toolName"] as? String ?? pending?.name
        let isError = message["isError"] as? Bool ?? false
        return [.toolCallUpdate(
            id: callId, title: name,
            kind: pending.map { PiFrameMapper.toolKind($0.name) },
            status: isError ? "failed" : "completed",
            content: (PiFrameMapper.diffBlock(from: message).map { [$0] } ?? [])
                + (pending.map { PiFrameMapper.headline(name: $0.name, arguments: $0.arguments) } ?? []),
            output: PiFrameMapper.resultContent(message["content"]),
            rawInput: pending?.arguments, oldText: nil)]
    }

    /// omp edit results ship the file diff as `details.diff` — the
    /// agent's own line format (` NN| ctx`, `+NN| add`, `-NN| del`)
    /// plus `path`, sometimes oldText/newText. Promote it to a LEADING
    /// {type:"diff"} content block so the UI renders the real diff
    /// (monocode parity): the block used to be dropped entirely, which
    /// is why history edit cards rendered as a bare "edit" with no body.
    static func diffBlock(from result: [String: Any]?) -> AgentContent? {
        guard let details = result?["details"] as? [String: Any],
              let diffText = details["diff"] as? String, !diffText.isEmpty else { return nil }
        return AgentContent(
            type: "diff",
            text: diffText,
            path: details["path"] as? String,
            oldText: details["oldText"] as? String,
            newText: details["newText"] as? String)
    }

    /// pi toolResult content: string, [{type:text,text}], or a raw value.
    static func resultContent(_ raw: Any?) -> [AgentContent] {
        if let text = raw as? String {
            return [AgentContent(type: "text", text: text, path: nil)]
        }
        if let blocks = raw as? [[String: Any]] {
            return blocks.compactMap { AgentContent($0) }
        }
        if let raw, let json = try? JSONSerialization.data(withJSONObject: raw),
           let text = String(data: json, encoding: .utf8) {
            return [AgentContent(type: "text", text: text, path: nil)]
        }
        return []
    }

    static func headline(name: String, arguments: [String: Any]?) -> [AgentContent] {
        let arguments = arguments ?? [:]
        let keys = ["command", "file_path", "path", "pattern", "url", "description", "query"]
        for key in keys {
            if let value = arguments[key] as? String, !value.isEmpty {
                return [AgentContent(type: "text", text: value, path: nil)]
            }
        }
        return []
    }

    static func toolKind(_ name: String) -> String {
        let lowered = name.lowercased()
        if lowered.contains("bash") || lowered.contains("exec") { return "execute" }
        if lowered.contains("read") { return "read" }
        if lowered.contains("edit") || lowered.contains("write") { return "edit" }
        if lowered.contains("grep") || lowered.contains("glob") || lowered.contains("search") { return "search" }
        if lowered.contains("fetch") || lowered.contains("web") { return "fetch" }
        return "other"
    }
}

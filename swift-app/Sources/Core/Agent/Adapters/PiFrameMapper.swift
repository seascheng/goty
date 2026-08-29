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
/// only replay emits userChunk.
final class PiFrameMapper {
    private var pendingTools: [String: (name: String, arguments: [String: Any]?)] = [:]
    private var completedTools: Set<String> = []

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
        case "agent_start", "turn_start", "message_start", "agent_end",
             "extension_ui_request":
            // Deltas and message_end carry the content; extension UI
            // requests (pi extensions' setStatus/setWidget) count but
            // do not render in v1.
            framesIgnored += 1
            return []
        default:
            framesIgnored += 1
            return []
        }
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
            if !text.isEmpty { events.append(.userChunk(text)) }
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
        case "text_delta":
            if let delta = event["delta"] as? String, !delta.isEmpty {
                return [.messageChunk(delta)]
            }
        case "thinking_delta":
            if let delta = event["delta"] as? String, !delta.isEmpty {
                return [.thoughtChunk(delta)]
            }
        default:
            break // start/end markers — boundaries, not content
        }
        return []
    }

    private func mapMessageEnd(_ frame: [String: Any]) -> [AgentSessionEvent] {
        guard let message = frame["message"] as? [String: Any] else { return [] }
        let role = message["role"] as? String ?? ""
        switch role {
        case "user":
            // Live echo suppressed (replay emits it via mapReplayedMessage).
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
            return events
        default:
            return []
        }
    }

    private func mapToolResults(_ raw: Any?) -> [AgentSessionEvent] {
        guard let results = raw as? [[String: Any]] else { return [] }
        return results.flatMap { toolResultCompleted($0) }
    }

    // MARK: - tool shaping

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
            content: pending.map { PiFrameMapper.headline(name: $0.name, arguments: $0.arguments) } ?? [],
            output: PiFrameMapper.resultContent(message["content"]),
            rawInput: pending?.arguments, oldText: nil)]
    }

    /// pi toolResult content: string, [{type:text,text}], or a raw value.
    static func resultContent(_ raw: Any?) -> [AgentContent] {
        if let text = raw as? String {
            return [AgentContent(type: "text", text: text, path: nil)]
        }
        if let blocks = raw as? [[String: Any]] {
            return blocks.compactMap { AgentContent($0) }
        }
        if raw != nil, let json = try? JSONSerialization.data(withJSONObject: raw),
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

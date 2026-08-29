// goty — see CLAUDE.md for the working principles.
import Foundation

/// claude stream-json SDK frames → AgentSessionEvent. Stateful: tool_use
/// declarations pair with later tool_result blocks by id, so the mapper
/// carries the pairing table across frames (live and replayed history
/// use the same vocabulary — the session jsonl IS the frame stream).
///
/// Shapes pinned by swift-app/tools/fixtures/claude-oneshot.jsonl
/// (claude 2.1.133, recorded 2026-08-29). Unknown frame types and hook
/// lifecycle noise are counted, never silently interpreted.
final class ClaudeFrameMapper {
    private(set) var sessionId: String?
    private(set) var model: String?
    /// tool_use id → (name, input, summary content) for result pairing.
    private struct PendingTool {
        let name: String
        let input: [String: Any]?
        let summary: [ACPContent]
    }
    private var pendingTools: [String: PendingTool] = [:]

    /// Integrity accounting (agenttest asserts these).
    private(set) var framesRouted = 0
    private(set) var framesIgnored = 0

    func map(_ frame: [String: Any]) -> [AgentSessionEvent] {
        framesRouted += 1
        guard let type = frame["type"] as? String else {
            framesIgnored += 1
            return []
        }
        switch type {
        case "system": return mapSystem(frame)
        case "assistant": return mapAssistant(frame)
        case "user": return mapUser(frame)
        case "result": return mapResult(frame)
        default:
            framesIgnored += 1
            return []
        }
    }

    // MARK: - system

    private func mapSystem(_ frame: [String: Any]) -> [AgentSessionEvent] {
        guard let subtype = frame["subtype"] as? String else {
            framesIgnored += 1
            return []
        }
        switch subtype {
        case "init":
            sessionId = frame["session_id"] as? String ?? sessionId
            model = frame["model"] as? String
            var events: [AgentSessionEvent] = [.ready]
            let commands = (frame["slash_commands"] as? [String] ?? [])
                .map { AgentSlashCommand(name: $0, description: nil, inputHint: nil) }
            if !commands.isEmpty {
                events.append(.commandsChanged(commands))
            }
            if let model {
                events.append(.configChanged([
                    AgentConfigOption(id: "model", name: "模型", category: nil,
                                      currentValue: model, options: []),
                ]))
            }
            return events
        case "hook_started", "hook_response", "status":
            // Hook lifecycle noise (user hooks fire per tool call); the
            // tool_use/tool_result pair already tells the story.
            framesIgnored += 1
            return []
        default:
            framesIgnored += 1
            return []
        }
    }

    // MARK: - assistant

    private func mapAssistant(_ frame: [String: Any]) -> [AgentSessionEvent] {
        let message = frame["message"] as? [String: Any] ?? [:]
        let blocks = message["content"] as? [[String: Any]] ?? []
        var events: [AgentSessionEvent] = []
        for block in blocks {
            guard let kind = block["type"] as? String else { continue }
            switch kind {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    events.append(.messageChunk(text))
                }
            case "thinking":
                if let text = block["thinking"] as? String, !text.isEmpty {
                    events.append(.thoughtChunk(text))
                }
            case "tool_use":
                guard let id = block["id"] as? String,
                      let name = block["name"] as? String else { continue }
                let input = block["input"] as? [String: Any]
                let summary = ClaudeFrameMapper.toolSummary(name: name, input: input)
                pendingTools[id] = PendingTool(name: name, input: input, summary: summary)
                events.append(.toolCallUpdate(id: id, title: name,
                                              kind: ClaudeFrameMapper.toolKind(name),
                                              status: "in_progress",
                                              content: summary, output: [],
                                              rawInput: input, oldText: nil))
            default:
                break
            }
        }
        return events
    }

    // MARK: - user (tool_result carrier)

    private func mapUser(_ frame: [String: Any]) -> [AgentSessionEvent] {
        let message = frame["message"] as? [String: Any] ?? [:]
        // History files carry user prompts as plain-string content (the
        // live --print stream never echoes them) — replay needs them as
        // userChunk so the transcript shows the asking side. Block-form
        // user frames are the tool_result carrier.
        if let text = message["content"] as? String, !text.isEmpty {
            return [.userChunk(text)]
        }
        let blocks = message["content"] as? [[String: Any]] ?? []
        var events: [AgentSessionEvent] = []
        for block in blocks {
            guard block["type"] as? String == "tool_result",
                  let callId = block["tool_use_id"] as? String else { continue }
            let pending = pendingTools.removeValue(forKey: callId)
            let isError = block["is_error"] as? Bool ?? false
            events.append(.toolCallUpdate(
                id: callId,
                title: pending?.name,
                kind: pending.map { ClaudeFrameMapper.toolKind($0.name) },
                status: isError ? "failed" : "completed",
                content: pending?.summary ?? [],
                output: ClaudeFrameMapper.normalizeContent(block["content"]),
                rawInput: pending?.input, oldText: nil))
        }
        return events
    }

    // MARK: - result

    private func mapResult(_ frame: [String: Any]) -> [AgentSessionEvent] {
        sessionId = frame["session_id"] as? String ?? sessionId
        var events: [AgentSessionEvent] = []
        if frame["is_error"] as? Bool == true,
           let text = frame["result"] as? String, !text.isEmpty {
            // The assistant text of a failed run would never arrive as an
            // assistant frame — the result string is all claude gives.
            events.append(.messageChunk(text))
        }
        if let usage = frame["usage"] as? [String: Any] {
            let inputTokens = usage["input_tokens"] as? Int
            let cacheRead = usage["cache_read_input_tokens"] as? Int
            let input = [inputTokens, cacheRead].compactMap { $0 }.reduce(0, +)
            let inputPresent = inputTokens != nil || cacheRead != nil
            let output = usage["output_tokens"] as? Int
            if inputPresent || output != nil {
                events.append(.usageUpdate(used: output, size: inputPresent ? input : nil,
                                           input: inputPresent ? input : nil, output: output,
                                           costAmount: nil, costCurrency: nil))
            }
        }
        let stop = frame["subtype"] as? String
        events.append(.turnEnded(stopReason: stop))
        return events
    }

    // MARK: - shared shaping

    /// tool_result content: string or [{type:"text",text:…}] → ACPContent.
    static func normalizeContent(_ raw: Any?) -> [ACPContent] {
        if let text = raw as? String {
            return [ACPContent(type: "text", text: text, path: nil)]
        }
        guard let blocks = raw as? [[String: Any]] else { return [] }
        return blocks.compactMap { ACPContent($0) }
    }

    /// One-line human summary of a tool call (its headline argument).
    static func toolSummary(name: String, input: [String: Any]?) -> [ACPContent] {
        let input = input ?? [:]
        let headline: String
        switch name {
        case "Bash", "BashOutput": headline = (input["command"] as? String) ?? ""
        case "Read", "Edit", "Write", "NotebookEdit":
            headline = (input["file_path"] as? String) ?? ""
        case "Grep", "Glob": headline = (input["pattern"] as? String) ?? ""
        case "Task": headline = (input["description"] as? String) ?? ""
        default:
            if let command = input["command"] as? String { headline = command }
            else if let path = input["file_path"] as? String { headline = path }
            else if let pattern = input["pattern"] as? String { headline = pattern }
            else if let desc = input["description"] as? String { headline = desc }
            else { headline = "" }
        }
        return headline.isEmpty ? [] : [ACPContent(type: "text", text: headline, path: nil)]
    }

    /// ACP-ish kind taxonomy for the tool card icon/tint.
    static func toolKind(_ name: String) -> String {
        switch name {
        case "Bash": return "execute"
        case "Read": return "read"
        case "Edit", "Write", "NotebookEdit": return "edit"
        case "Grep", "Glob": return "search"
        case "Task": return "agent"
        case "WebFetch", "WebSearch": return "fetch"
        default: return "other"
        }
    }
}

// goty — see CLAUDE.md for the working principles.
import Foundation

/// codex app-server notifications → AgentSessionEvent. Shapes pinned by
/// swift-app/tools/fixtures/codex-turn.jsonl (codex-cli 0.147.0,
/// recorded 2026-08-29): item/started + item/completed carry the item
/// payload (userMessage, assistantMessage, reasoning, commandExecution,
/// fileChange, …), turn/completed ends a turn with status + error, and
/// approval requests arrive as server→client JSON-RPC requests (the
/// session owns those, not this mapper).
///
/// Text dedup: an item's content may arrive on started AND completed
/// (userMessage did in the fixture); each item id's text is emitted
/// once. Unknown item types become generic tool cards — counted, never
/// silently dropped.
final class CodexFrameMapper {
    private var emittedText: Set<String> = []
    private var itemTitles: [String: String] = [:]

    /// Integrity accounting (agenttest asserts these).
    private(set) var notificationsRouted = 0
    private(set) var notificationsIgnored = 0
    private(set) var unknownItemTypes = 0

    /// One notification (`item/started`, `item/completed`,
    /// `turn/completed`, …). Returns the events for it.
    func map(method: String, params: [String: Any]) -> [AgentSessionEvent] {
        notificationsRouted += 1
        switch method {
        case "item/started", "item/completed":
            return mapItem(params,
                           completed: method == "item/completed")
        case "turn/completed":
            return mapTurnCompleted(params)
        case "error":
            // Retry chatter ("Reconnecting... 1/5") — the definitive
            // failure lands on turn/completed with the last error.
            notificationsIgnored += 1
            return []
        case "thread/started", "thread/status/changed", "turn/started",
             "warning", "mcpServer/startupStatus/updated",
             "remoteControl/status/changed":
            notificationsIgnored += 1
            return []
        default:
            notificationsIgnored += 1
            return []
        }
    }

    private func mapItem(_ params: [String: Any], completed: Bool) -> [AgentSessionEvent] {
        guard let item = params["item"] as? [String: Any],
              let id = item["id"] as? String,
              let type = item["type"] as? String else {
            notificationsIgnored += 1
            return []
        }
        switch type {
        case "userMessage":
            let text = CodexFrameMapper.textOf(item["content"])
            guard !text.isEmpty, !emittedText.contains(id) else { return [] }
            emittedText.insert(id)
            return [.userChunk(text)]
        case "assistantMessage":
            let text = CodexFrameMapper.textOf(item["content"])
            guard !text.isEmpty, !emittedText.contains(id) else { return [] }
            emittedText.insert(id)
            return [.messageChunk(text)]
        case "reasoning":
            let text = CodexFrameMapper.textOf(item["text"] ?? item["content"])
            guard !text.isEmpty, !emittedText.contains(id) else { return [] }
            emittedText.insert(id)
            return [.thoughtChunk(text)]
        case "commandExecution":
            let command = (item["command"] as? [String: Any])?["command"] as? String
                ?? (item["command"] as? String) ?? ""
            itemTitles[id] = command
            var exitCode: Int?
            if completed, let code = item["exitCode"] as? Int { exitCode = code }
            return [.toolCallUpdate(
                id: id, title: command.isEmpty ? "command" : command,
                kind: "execute",
                status: completed ? (exitCode == nil || exitCode == 0 ? "completed" : "failed") : "in_progress",
                content: command.isEmpty ? [] : [ACPContent(type: "text", text: command, path: nil)],
                output: completed ? [ACPContent(type: "text",
                                                text: "exit \(exitCode.map(String.init) ?? "?")",
                                                path: nil)] : [],
                rawInput: command.isEmpty ? nil : ["command": command],
                oldText: nil)]
        case "fileChange":
            let path = item["path"] as? String ?? ""
            itemTitles[id] = path
            return [.toolCallUpdate(
                id: id, title: path.isEmpty ? "file change" : path, kind: "edit",
                status: completed ? "completed" : "in_progress",
                content: path.isEmpty ? [] : [ACPContent(type: "path", text: nil, path: path)],
                output: [], rawInput: path.isEmpty ? nil : ["path": path], oldText: nil)]
        default:
            unknownItemTypes += 1
            let title = itemTitles[id] ?? type
            return [.toolCallUpdate(
                id: id, title: title, kind: "other",
                status: completed ? "completed" : "in_progress",
                content: [ACPContent(type: "text", text: type, path: nil)],
                output: [], rawInput: nil, oldText: nil)]
        }
    }

    private func mapTurnCompleted(_ params: [String: Any]) -> [AgentSessionEvent] {
        let turn = params["turn"] as? [String: Any] ?? [:]
        var events: [AgentSessionEvent] = []
        if let error = turn["error"] as? [String: Any],
           let message = error["message"] as? String, !message.isEmpty {
            events.append(.messageChunk("[codex] \(message)"))
        }
        let status = turn["status"] as? String
        events.append(.turnEnded(stopReason: status))
        return events
    }

    /// codex content: [{type:"text",text:…}] (also tolerates raw string).
    static func textOf(_ raw: Any?) -> String {
        if let text = raw as? String { return text }
        guard let blocks = raw as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["text"] as? String }.joined()
    }
}

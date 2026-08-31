// goty — see CLAUDE.md for the working principles.
import Foundation

/// omp's session store: `~/.omp/agent/sessions/<cwd-dir>/<timestamp>_<sid>.jsonl`.
/// ONE JSON object per line; this file is the agent's authoritative
/// conversation record — the omp TUI renders its history from exactly
/// this file, so reading it here is what makes our recovery TUI-grade:
///
/// - user prompts ARE in the store (the ACP update stream never echoes
///   them — recovering from the wire alone lost the user's side);
/// - the FINAL assistant entry carries `stopReason` ("aborted" when the
///   turn was interrupted) — the wire never delivers one for a dead
///   turn, which is why a recovered pane could look stuck "working";
/// - the `title` line is omp's own naming (empty until a turn completes
///   normally — aborted sessions legitimately have no name).
enum OmpSessionStore {
    struct Loaded {
        var events: [AgentSessionEvent]
        var aborted: Bool
        var title: String?
    }

    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".omp/agent/sessions", isDirectory: true)
    }

    /// Locate `<…>_<sessionId>.jsonl` across all cwd directories.
    static func fileURL(sessionId: String) -> URL? {
        let suffix = "_" + sessionId + ".jsonl"
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs where dir.hasDirectoryPath {
            let candidate = dir.appendingPathComponent(suffix)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Authoritative recovery for one session: full history (user side
    /// included) as render events, plus whether its last turn was
    /// aborted, plus omp's title (nil when unnamed).
    static func load(sessionId: String) -> Loaded {
        guard let url = fileURL(sessionId: sessionId),
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            NSLog("GOTY omp store: no file for %@", sessionId)
            return Loaded(events: [], aborted: false, title: nil)
        }
        var events: [AgentSessionEvent] = []
        var aborted = false
        var title: String?
        var lastAssistantStop: String?

        for line in raw.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data),
                  let entry = obj as? [String: Any] else { continue }
            switch entry["type"] as? String {
            case "title":
                title = entry["title"] as? String
            case "message":
                guard let message = entry["message"] as? [String: Any] else { break }
                let role = message["role"] as? String
                let blocks = (message["content"] as? [[String: Any]]) ?? []
                switch role {
                case "user":
                    for block in blocks where block["type"] as? String == "text" {
                        if let text = block["text"] as? String, !text.isEmpty {
                            events.append(.userChunk(text))
                        }
                    }
                case "assistant":
                    if let stop = message["stopReason"] as? String { lastAssistantStop = stop }
                    for block in blocks {
                        switch block["type"] as? String {
                        case "thinking":
                            if let text = block["thinking"] as? String, !text.isEmpty {
                                events.append(.thoughtChunk(text))
                            }
                        case "text":
                            if let text = block["text"] as? String, !text.isEmpty {
                                events.append(.messageChunk(text))
                            }
                        default:
                            break
                        }
                    }
                case "toolResult":
                    if let toolCallId = message["toolCallId"] as? String {
                        let content = ACPContentNormalizer.flatten(
                            message["content"] as? [[String: Any]])
                        events.append(.toolCallUpdate(
                            id: toolCallId,
                            title: message["toolName"] as? String,
                            kind: nil,
                            status: "completed",
                            content: content,
                            output: ACPContentNormalizer.resultItems(
                                rawOutput: ["content": (message["content"] as? [[String: Any]]) ?? []]),
                            rawInput: nil,
                            oldText: nil))
                    }
                default:
                    break
                }
            case "custom":
                guard entry["customType"] as? String == "tool_execution_start",
                      let data = entry["data"] as? [String: Any],
                      let toolCallId = data["toolCallId"] as? String else { break }
                let intent = (data["intent"] as? String) ?? (data["toolName"] as? String) ?? "tool"
                events.append(.toolCallUpdate(
                    id: toolCallId,
                    title: intent,
                    kind: nil,
                    status: "in_progress",
                    content: [],
                    output: [],
                    rawInput: nil,
                    oldText: nil))
            default:
                break
            }
        }
        aborted = lastAssistantStop == "aborted"
        return Loaded(events: events, aborted: aborted, title: title)
    }

    /// omp names a session only after a turn completes normally — an
    /// aborted session has an empty title in its store.
    static func sessionTitle(sessionId: String) -> String? {
        guard let url = fileURL(sessionId: sessionId),
              let raw = try? String(contentsOf: url, encoding: .utf8),
              let first = raw.split(separator: "\n").first,
              let data = first.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "title" else { return nil }
        let title = obj["title"] as? String ?? ""
        return title.isEmpty ? nil : title
    }
}

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

    /// Locate `<timestamp>_<sessionId>.jsonl` across all cwd directories
    /// by SUFFIX — the timestamp prefix is not derivable from the id.
    /// (An exact-name probe matched nothing: every spawn silently lost
    /// --resume and session switching spawned fresh conversations.)
    static func fileURL(sessionId: String) -> URL? {
        let suffix = "_" + sessionId + ".jsonl"
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs where dir.hasDirectoryPath {
            let files = (try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent.hasSuffix(suffix) {
                return file
            }
        }
        return nil
    }

    /// First `bytes` of a store file — the title slot and the session
    /// line both live at the head. The store holds hundreds of files
    /// (100+ MB total); reading each IN FULL for a list query stalled
    /// the history panel for seconds.
    private static func readHead(of file: URL, bytes: Int = 4096) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// History list for one workspace: every store file under the
    /// sessions root, filtered by the pane cwd prefix, newest first.
    /// The title comes from the title line (omp rewrites a 256-byte slot
    /// in place — first-line read sees the current value); the session
    /// id from the filename suffix.
    static func summaries(cwd: String?) -> [AgentSessionSummary] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        var out: [AgentSessionSummary] = []
        for dir in dirs where dir.hasDirectoryPath {
            let files = (try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                let name = file.deletingPathExtension().lastPathComponent
                guard let underscore = name.lastIndex(of: "_") else { continue }
                let sid = String(name[name.index(after: underscore)...])
                guard sid.contains("-"), sid.count >= 30 else { continue }
                guard let raw = readHead(of: file),
                      let first = raw.split(separator: "\n").first,
                      let data = first.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data),
                      let record = json as? [String: Any] else { continue }
                var sessionCwd: String?
                var title: String?
                if record["type"] as? String == "title" {
                    title = record["title"] as? String
                }
                // The session line carries the cwd; the title line may
                // come first — scan the first few lines for both.
                for line in raw.split(separator: "\n").prefix(6) {
                    guard let d = line.data(using: .utf8),
                          let j = try? JSONSerialization.jsonObject(with: d),
                          let rec = j as? [String: Any] else { continue }
                    if rec["type"] as? String == "session" {
                        sessionCwd = rec["cwd"] as? String
                    }
                    if rec["type"] as? String == "title", title == nil {
                        title = rec["title"] as? String
                    }
                }
                if let cwd, let sessionCwd, !sessionCwd.hasPrefix(cwd) { continue }
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                let updated = date?.timeIntervalSince1970 ?? 0
                let cleanTitle = (title ?? "").isEmpty ? nil : title
                out.append(AgentSessionSummary(
                    sessionId: sid, cwd: sessionCwd, title: cleanTitle,
                    updatedAt: String(Int(updated)), messageCount: nil))
            }
        }
        return out.sorted { (Int($0.updatedAt ?? "") ?? 0) > (Int($1.updatedAt ?? "") ?? 0) }
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
                            events.append(.userMessage(text))
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
              let raw = readHead(of: url, bytes: 512),
              let first = raw.split(separator: "\n").first,
              let data = first.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "title" else { return nil }
        let title = obj["title"] as? String ?? ""
        return title.isEmpty ? nil : title
    }
}

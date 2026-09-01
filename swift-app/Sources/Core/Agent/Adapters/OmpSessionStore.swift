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
        /// Tool calls the file shows as started but never completed.
        /// An idle, non-aborted session with open tools means the read
        /// raced the settle (store write lagged) — the transcript tail
        /// would freeze those cards at 运行中 forever. Caller re-reads.
        var openTools: Int = 0
        /// Tail-first reads anchor the truncation here: the entry id of
        /// the FIRST included line. loadOlderHistory re-parses the file
        /// up to (exclusive) this entry. nil = the load was complete.
        var firstEntryId: String? = nil
    }

    /// Test seam: when set, everything resolves here instead of the
    /// real store (agenttest fixture isolation).
    static var rootOverride: URL?

    static var root: URL {
        rootOverride ?? FileManager.default.homeDirectoryForCurrentUser
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
        return parse(raw)
    }

    /// Raw JSONL → events. Split from load(): remote panes fetch the
    /// same bytes through their daemon and parse identically.
    static func parse(_ raw: String) -> Loaded {
        var events: [AgentSessionEvent] = []
        var openToolIds: Set<String> = []
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
                    // Session-tree anchor: entries carry their tree id —
                    // the 分支 button on a user bubble targets exactly
                    // this entry (omp /branch semantics).
                    if let entryId = entry["id"] as? String {
                        events.append(.entryMark(role: "user", entryId: entryId))
                    }
                case "assistant":
                    if let stop = message["stopReason"] as? String { lastAssistantStop = stop }
                    var firstBlock = true
                    for block in blocks {
                        switch block["type"] as? String {
                        case "thinking":
                            if let text = block["thinking"] as? String, !text.isEmpty {
                                if !firstBlock { events.append(.chunkBoundary) }
                                events.append(.thoughtChunk(text))
                                firstBlock = false
                            }
                        case "text":
                            if let text = block["text"] as? String, !text.isEmpty {
                                if !firstBlock { events.append(.chunkBoundary) }
                                events.append(.messageChunk(text))
                                firstBlock = false
                            }
                        default:
                            break
                        }
                    }
                    if let entryId = entry["id"] as? String {
                        events.append(.entryMark(role: "agent", entryId: entryId))
                    }
                case "toolResult":
                    if let toolCallId = message["toolCallId"] as? String {
                        openToolIds.remove(toolCallId)
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
                let toolName = (data["toolName"] as? String) ?? "tool"
                let intent = (data["intent"] as? String) ?? toolName
                // Parity with the LIVE frame path (PiFrameMapper
                // mapToolExecutionStart): replayed tool cards keep the
                // same title derivation — kind + raw args — so "Read
                // path:1-3" survives a restart instead of degrading to
                // icon + intent.
                let arguments = data["args"] as? [String: Any]
                events.append(.toolCallUpdate(
                    id: toolCallId,
                    title: intent,
                    kind: PiFrameMapper.toolKind(toolName),
                    status: "in_progress",
                    content: [],
                    output: [],
                    rawInput: arguments,
                    oldText: nil))
                openToolIds.insert(toolCallId)
            default:
                break
            }
        }
        aborted = lastAssistantStop == "aborted"
        return Loaded(events: events, aborted: aborted, title: title,
                      openTools: openToolIds.count)
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

    // MARK: - offline fork (probed 2026-09-01: omp accepts a hand-made
    // prefix fork — 256-byte title slot {type:"title",v:1,title,
    // updatedAt,pad} + session header {version:3, new id} + verbatim
    // source entries; boots in <1s vs 13.6s for the process round-trip)

    /// UUIDv7, omp's session-id shape (timestamp-prefixed).
    static func uuidv7() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let ms = UInt64(Date().timeIntervalSince1970 * 1000)
        for i in 0..<6 {
            bytes[i] = UInt8((ms >> (8 * UInt64(5 - i))) & 0xFF)
        }
        var random = SystemRandomNumberGenerator()
        for i in 6..<16 {
            bytes[i] = UInt8(random.next() % 256)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x70   // version 7
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                           bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
            .uuidString.lowercased()
    }

    /// Fork the source session file at an entry, OFFLINE: write a new
    /// store file = slot + fresh header + verbatim prefix through the
    /// entry's turn. ~10ms of file I/O; no omp process involved.
    /// Returns the new session id, nil when the source/entry is gone.
    static func forkFile(sourceId: String, entryId: String) -> String? {
        guard let srcURL = fileURL(sessionId: sourceId),
              let raw = try? String(contentsOf: srcURL, encoding: .utf8)
        else { return nil }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > 2 else { return nil }

        func field(_ line: Substring, _ key: String) -> String? {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data)
                      as? [String: Any] else { return nil }
            if key == "role" {
                return ((obj["message"] as? [String: Any])?["role"]) as? String
            }
            return obj[key] as? String
        }

        // Locate the entry; extend a USER cut through its turn (until
        // the next user message entry) so the fork keeps the reply.
        guard let target = lines.firstIndex(where: { field($0, "id") == entryId })
        else { return nil }
        var cut = target
        if field(lines[target], "role") == "user" {
            if let next = lines[(target + 1)...].firstIndex(where: {
                field($0, "role") == "user"
            }) {
                cut = next - 1
            } else {
                cut = lines.count - 1
            }
        }

        let newId = uuidv7()
        let ms = Int(Date().timeIntervalSince1970 * 1000)
        let seconds = ms / 1000
        var time = time_t(seconds)
        var tmv = tm()
        gmtime_r(&time, &tmv)
        let h = { String(format: "%02d", $0) }
        let stampMs = String(format: "%03d", ms % 1000)
        // header: colons; filename: dashes (omp's own convention)
        let headerTime = "\(tmv.tm_year + 1900)-\(h(tmv.tm_mon + 1))-\(h(tmv.tm_mday))"
            + "T\(h(tmv.tm_hour)):\(h(tmv.tm_min)):\(h(tmv.tm_sec)).\(stampMs)Z"
        let fileTime = "\(tmv.tm_year + 1900)-\(h(tmv.tm_mon + 1))-\(h(tmv.tm_mday))"
            + "T\(h(tmv.tm_hour))-\(h(tmv.tm_min))-\(h(tmv.tm_sec))-\(stampMs)Z"

        var slot = "{\"type\":\"title\",\"v\":1,\"title\":\"\",\"updatedAt\":"
            + "\"\(headerTime)\",\"pad\":\"\"}"
        if slot.utf8.count < 255 {
            let pad = String(repeating: " ", count: 255 - slot.utf8.count)
            slot = String(slot.dropLast(2)) + pad + "\"}"
        }

        // cwd rides the source's session header (line 2, after the slot).
        let sourceCwd = field(lines[1], "cwd") ?? ""
        let header = "{\"type\":\"session\",\"version\":3,\"id\":\"\(newId)\","
            + "\"timestamp\":\"\(headerTime)\",\"cwd\":\"\(sourceCwd)\"}"

        var out = [slot, header]
        out += lines[2...cut].map(String.init)
        let dest = srcURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileTime)_\(newId).jsonl")
        do {
            try out.joined(separator: "\n").appending("\n")
                .write(to: dest, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        return newId
    }

    // MARK: - tail-first load (happier coldOpenAtBottom, distilled)

    /// Take the tail of a FULL file's raw text (already read via daemon
    /// or local disk) and cut it at a TURN boundary: from the byte cut,
    /// advance to the first USER message entry so the seam can never
    /// split a turn. Returns the slice + its anchor entry id (nil when
    /// the file fits whole — then callers parse the full raw).
    static func tailSlice(_ raw: String, maxBytes: Int = 512 * 1024)
            -> (slice: String, firstEntryId: String?) {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 2 else { return (raw, nil) }
        var bytes = 0
        var cut = lines.count
        for i in stride(from: lines.count - 1, through: 2, by: -1) {
            bytes += lines[i].utf8.count + 1
            if bytes > maxBytes { cut = i + 1; break }
        }
        if cut <= 2 { return (raw, nil) }   // window covers (almost) all
        // Advance to a turn seam: the first user-message entry at/after
        // the cut. If none lands within the window, keep everything.
        var seam = cut
        for i in cut..<lines.count {
            guard let data = lines[i].data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data)
                      as? [String: Any],
                  obj["type"] as? String == "message",
                  (obj["message"] as? [String: Any])?["role"] as? String == "user"
            else { continue }
            seam = i
            break
        }
        guard seam > 2, seam < lines.count else { return (raw, nil) }
        let anchor = lines[seam].data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0["id"] as? String }
        let slice = lines[seam...].joined(separator: "\n")
        return (slice, anchor)
    }

    /// Older portion of a file, EXCLUSIVE of the anchor entry: the
    /// events lines[2..<anchorIndex) produce. Feeds transcriptPrepend.
    static func parseOlder(_ raw: String, beforeEntryId anchor: String) -> Loaded {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        guard let cut = lines.firstIndex(where: { line in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data)
                      as? [String: Any] else { return false }
            return obj["id"] as? String == anchor
        }) else {
            return Loaded(events: [], aborted: false, title: nil)
        }
        guard cut > 2 else { return Loaded(events: [], aborted: false, title: nil) }
        let older = lines[2..<cut].joined(separator: "\n")
        return parse(older)
    }
}

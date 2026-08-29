// goty — see CLAUDE.md for the working principles.
import Foundation

/// Reader for claude's persisted sessions: `~/.claude/projects/<dir-
/// slug>/<session_id>.jsonl`, one SDK frame per line. Listing scans the
/// FIRST line of each file (system/init carries session_id, cwd and the
/// model; mtime orders) — no slug reverse-engineering, so claude's
/// dir-naming scheme (dots/underscores both collapse to dashes) stays
/// their business.
///
/// The jsonl frames use the live stream-json vocabulary, so history
/// replay is literally ClaudeFrameMapper over the file's lines.
enum ClaudeSessionStore {
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    /// Sessions newest-first; `cwd` filters by working directory when
    /// the pane knows one (prefix match — claude stores absolute paths).
    static func summaries(cwd: String?) -> [AgentSessionSummary] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root,
                                                     includingPropertiesForKeys: nil) else {
            return []
        }
        var out: [AgentSessionSummary] = []
        for dir in dirs {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let first = readFirstLine(file) ,
                      let data = first.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data),
                      let frame = json as? [String: Any],
                      frame["type"] as? String == "system",
                      frame["subtype"] as? String == "init" else {
                    continue
                }
                let sid = (frame["session_id"] as? String) ?? stem(of: file)
                let frameCwd = frame["cwd"] as? String
                if let cwd, let frameCwd, !frameCwd.hasPrefix(cwd) { continue }
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate)?.timeIntervalSince1970
                out.append(AgentSessionSummary(
                    sessionId: sid, cwd: frameCwd,
                    title: (frame["model"] as? String).map { "claude · \($0)" },
                    updatedAt: mtime.map { String(Int($0)) },
                    messageCount: nil))
            }
        }
        return out.sorted { (Int($0.updatedAt ?? "") ?? 0) > (Int($1.updatedAt ?? "") ?? 0) }
    }

    /// All frames of one session, oldest first. Unparseable lines are
    /// skipped and counted in `skippedLines` (returned by reference —
    /// callers log it; silence is how the last content-loss bug hid).
    static func history(sessionId: String, skippedLines: UnsafeMutablePointer<Int>? = nil) -> [[String: Any]] {
        guard let file = find(sessionId: sessionId) else { return [] }
        var frames: [[String: Any]] = []
        var skipped = 0
        guard let stream = InputStream(url: file) else { return [] }
        stream.open()
        defer { stream.close() }
        var buffered = BufferedLineReader(stream: stream)
        while let line = buffered.nextLine() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data),
                  let frame = json as? [String: Any] else {
                skipped += 1
                continue
            }
            frames.append(frame)
        }
        skippedLines?.pointee += skipped
        return frames
    }

    static func find(sessionId: String) -> URL? {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root,
                                                     includingPropertiesForKeys: nil) else {
            return nil
        }
        for dir in dirs {
            let candidate = dir.appendingPathComponent("\(sessionId).jsonl")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static func stem(of file: URL) -> String {
        file.deletingPathExtension().lastPathComponent
    }

    private static func readFirstLine(_ file: URL) -> String? {
        guard let stream = InputStream(url: file) else { return nil }
        stream.open()
        defer { stream.close() }
        var reader = BufferedLineReader(stream: stream)
        return reader.nextLine()
    }
}

/// Minimal allocation-light line reader over a mapped InputStream —
/// session files run to tens of MB and String(contentsOf:) would copy
/// the whole file.
struct BufferedLineReader {
    private let stream: InputStream
    private var buffer = [UInt8]()
    private var scratch = [UInt8](repeating: 0, count: 1 << 16)
    private var done = false

    init(stream: InputStream) {
        self.stream = stream
    }

    mutating func nextLine() -> String? {
        while true {
            if let idx = buffer.firstIndex(of: 0x0A) {
                var line = Array(buffer[0..<idx])
                buffer.removeSubrange(0...idx)
                if line.last == 0x0D { line.removeLast() }
                guard !line.isEmpty else { continue }
                return String(decoding: line, as: UTF8.self)
            }
            if done {
                if buffer.isEmpty { return nil }
                let line = buffer
                buffer = []
                return String(decoding: line, as: UTF8.self)
            }
            let n = stream.read(&scratch, maxLength: scratch.count)
            if n <= 0 {
                done = true
                continue
            }
            buffer.append(contentsOf: scratch[0..<n])
        }
    }
}

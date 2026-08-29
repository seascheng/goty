// goty — see CLAUDE.md for the working principles.
import Foundation

/// Reader for pi's persisted sessions: `~/.pi/agent/sessions/<slug>/
/// <timestamp>_<uuid>.jsonl` (the omp layout — omp is a pi fork). The
/// first line is a session record carrying id, timestamp and cwd, so
/// listing is a first-line scan with no slug reverse-engineering.
enum PiSessionStore {
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/sessions")
    }

    static func summaries(cwd: String?) -> [AgentSessionSummary] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root,
                                                     includingPropertiesForKeys: nil) else {
            return []
        }
        var out: [AgentSessionSummary] = []
        for dir in dirs {
            let files = (try? fm.contentsOfDirectory(at: dir,
                                                     includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard var reader = openReader(file), let line = reader.nextLine(),
                      let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data),
                      let record = json as? [String: Any],
                      record["type"] as? String == "session" else { continue }
                guard let sid = (record["id"] as? String) ?? stemUUID(of: file) else { continue }
                let sessionCwd = record["cwd"] as? String
                if let cwd, let sessionCwd, !sessionCwd.hasPrefix(cwd) { continue }
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                let updated = date?.timeIntervalSince1970
                    ?? timestamp(record["timestamp"]) ?? 0
                out.append(AgentSessionSummary(
                    sessionId: sid, cwd: sessionCwd,
                    title: (record["name"] as? String),
                    updatedAt: String(Int(updated)),
                    messageCount: nil))
            }
        }
        return out.sorted { (Int($0.updatedAt ?? "") ?? 0) > (Int($1.updatedAt ?? "") ?? 0) }
    }

    static func find(sessionId: String) -> URL? {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root,
                                                     includingPropertiesForKeys: nil) else {
            return nil
        }
        for dir in dirs {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent.contains(sessionId) {
                return file
            }
        }
        return nil
    }

    // MARK: - helpers

    private static func openReader(_ file: URL) -> BufferedLineReader? {
        guard let stream = InputStream(url: file) else { return nil }
        stream.open()
        guard stream.streamError == nil || stream.hasBytesAvailable else {
            stream.close()
            return nil
        }
        return BufferedLineReader(stream: stream)
    }

    private static func stemUUID(of file: URL) -> String? {
        // File name: 2026-08-29T03-35-00-395Z_<uuid>.jsonl
        let stem = file.deletingPathExtension().lastPathComponent
        guard let range = stem.range(of: "_") else { return nil }
        return String(stem[range.upperBound...])
    }

    private static func timestamp(_ raw: Any?) -> TimeInterval? {
        guard let iso = raw as? String else { return 0 }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: iso)?.timeIntervalSince1970 ?? 0
    }
}

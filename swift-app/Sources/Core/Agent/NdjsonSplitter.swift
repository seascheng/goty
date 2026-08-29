// goty — see CLAUDE.md for the working principles.
import Foundation

/// Incremental ndjson line splitter over the agent pane's byte stream.
/// Lines may straddle chunk boundaries; every buffer position is scanned
/// exactly once (the scan watermark), so multi-MB replay lines never
/// cost quadratic time.
struct NdjsonSplitter {
    private var buffer: [UInt8] = []
    /// Prefix length of `buffer` already known to contain no 0x0A.
    private var scanned = 0
    /// A line cannot exceed a sessiond frame (16 MiB); past 64 MiB with
    /// no newline the stream is garbage — dropped loudly, never silently.
    private static let dropLine = 64 * 1024 * 1024

    mutating func feed(_ bytes: [UInt8]) -> [String] {
        buffer.append(contentsOf: bytes)
        var lines: [String] = []
        var start = 0
        var i = scanned
        while i < buffer.count {
            if buffer[i] == 0x0A {
                var line = buffer[start..<i]
                if line.last == 0x0D { line = line.dropLast() }
                if let text = String(bytes: line, encoding: .utf8), !text.isEmpty {
                    lines.append(text)
                }
                start = i + 1
            }
            i += 1
        }
        scanned = buffer.count - start
        if start > 0 { buffer.removeSubrange(..<start) }
        if buffer.count > Self.dropLine {
            FileHandle.standardError.write(
                "acp: dropping \(buffer.count)B newline-less garbage (not valid ndjson)\n"
                    .data(using: .utf8)!)
            buffer.removeAll(keepingCapacity: true)
            scanned = 0
        }
        return lines
    }
}

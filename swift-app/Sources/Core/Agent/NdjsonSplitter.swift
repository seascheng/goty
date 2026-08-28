// goty — see CLAUDE.md for the working principles.
import Foundation

/// Incremental ndjson line splitter over the agent pane's byte stream.
/// Lines may straddle chunk boundaries; an over-long line (no \n within
/// 1 MiB) is discarded whole — it cannot be valid ACP traffic.
struct NdjsonSplitter {
    private var buffer: [UInt8] = []
    private static let maxLine = 1024 * 1024

    mutating func feed(_ bytes: [UInt8]) -> [String] {
        buffer.append(contentsOf: bytes)
        var lines: [String] = []
        var start = 0
        for i in buffer.indices where buffer[i] == 0x0A {
            var line = buffer[start..<i]
            if line.last == 0x0D { line = line.dropLast() }
            if let text = String(bytes: line, encoding: .utf8), !text.isEmpty {
                lines.append(text)
            }
            start = i + 1
        }
        buffer.removeSubrange(..<start)
        if buffer.count > Self.maxLine { buffer.removeAll(keepingCapacity: true) }
        return lines
    }
}

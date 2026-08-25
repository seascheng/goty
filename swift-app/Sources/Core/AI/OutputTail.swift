// OutputTail — 8KB ring of raw pane output, ANSI-stripped on read for the
// AI context window. Feeds from the terminal stream queue, so all state
// lives under a lock.
import Foundation

final class OutputTail {
    private var ring: [UInt8] = []
    private let lock = NSLock()
    private static let capacity = 8192
    private static let maxLines = 64

    func append(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        lock.lock()
        ring.append(contentsOf: bytes)
        if ring.count > Self.capacity {
            ring.removeFirst(ring.count - Self.capacity)
        }
        lock.unlock()
    }

    var snapshot: String {
        lock.lock()
        defer { lock.unlock() }
        return Self.stripped(ring)
    }

    /// Decode, strip escape sequences, keep the last 64 non-empty lines.
    /// CSI: ESC [ ... final byte 0x40–0x7E. OSC: ESC ] ... BEL or ST
    /// (ESC \). Other two-char ESC sequences: ESC + one byte.
    static func stripped(_ bytes: [UInt8]) -> String {
        var text: [UInt8] = []
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x1B, i + 1 < bytes.count {
                let next = bytes[i + 1]
                if next == UInt8(ascii: "[") {              // CSI
                    i += 2
                    while i < bytes.count, !(0x40...0x7E).contains(bytes[i]) { i += 1 }
                    i += 1                                   // consume final byte
                    continue
                }
                if next == UInt8(ascii: "]") {              // OSC
                    i += 2
                    while i < bytes.count {
                        if bytes[i] == 0x07 { i += 1; break }
                        if bytes[i] == 0x1B, i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "\\") { i += 2; break }
                        i += 1
                    }
                    continue
                }
                i += 2                                       // ESC + one char
                continue
            }
            if b == 0x0D { i += 1; continue }                // drop \r
            text.append(b)
            i += 1
        }
        let decoded = String(decoding: text, as: UTF8.self)
        let lines = decoded.split(separator: "\n", omittingEmptySubsequences: true)
        return lines.suffix(maxLines).joined(separator: "\n")
    }
}

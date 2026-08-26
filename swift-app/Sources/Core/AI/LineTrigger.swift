// LineTrigger — byte-level input-line tracker at the PTY chokepoint.
// CSI (ESC [ …0x40–0x7E) and SS3 (ESC O x) sequences pass through to the
// shell but never feed the line accumulator — the trailing letter of an
// arrow key used to land in the buffer (ESC O A → "OA" + "@ai…" never
// matched the prefix and the line fell through to the shell). No
// readline emulation beyond that: text the shell re-edits via arrows can
// still desync — ctrl-u always clears both sides, so the worst case is a
// wrong request string, never a stale executed command.
import Foundation

final class LineTrigger {
    var armed = false
    var onTrigger: ((String) -> Void)?
    private var line: [UInt8] = []
    private static let prefix: [UInt8] = Array("@ai".utf8)
    /// Escape-sequence parser state: inside CSI / inside SS3.
    private var inCsi = false
    private var inSs3 = false

    func filter(_ bytes: [UInt8]) -> [UInt8] {
        guard armed else { line = []; inCsi = false; inSs3 = false; return bytes }
        var out: [UInt8] = []
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            // Inside an escape sequence: forward untouched, feed nothing.
            if inSs3 {
                inSs3 = false  // one following byte completes SS3
                out.append(b)
                i += 1
                continue
            }
            if inCsi {
                if b >= 0x40 && b <= 0x7E { inCsi = false }  // final byte
                out.append(b)
                i += 1
                continue
            }
            switch b {
            case 0x5B where i > 0 && bytes[i - 1] == 0x1B:
                inCsi = true  // '[' right after ESC opens CSI
                out.append(b)
            case 0x4F where i > 0 && bytes[i - 1] == 0x1B:
                inSs3 = true  // 'O' right after ESC opens SS3
                out.append(b)
            case 0x0D, 0x0A:
                let isTrigger = line.starts(with: Self.prefix) && line.count > Self.prefix.count
                if ProcessInfo.processInfo.environment["GOTY_AI_DEBUG"] == "1", !line.isEmpty {
                    FileHandle.standardError.write("AILINE armed=\(armed) line=\(String(decoding: line.prefix(24), as: UTF8.self)) trigger=\(isTrigger)\n".data(using: .utf8)!)
                }
                if isTrigger {
                    let text = String(decoding: line.dropFirst(Self.prefix.count), as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    line = []
                    onTrigger?(text)
                    return out  // swallow this enter (and anything after in the same chunk)
                }
                line = []
                out.append(b)
            case 0x7F, 0x08:
                // Clamp at the trigger prefix: backspacing into "@ai"
                // would silently disarm the trigger for the rest of the
                // line — the prefix is kept and the delete is dropped
                // (the shell still sees the backspace byte).
                if line.count > Self.prefix.count {
                    line.removeLast()
                    while let last = line.last, last & 0xC0 == 0x80, line.count > Self.prefix.count {
                        line.removeLast()  // UTF-8 continuation
                    }
                }
                out.append(b)
            case 0x15:  // ctrl-u clears the shell line — mirror it
                line = []
                out.append(b)
            case 0x03:  // ctrl-c
                line = []
                out.append(b)
            default:
                // ESC alone forwards through (the [ / O check happens on
                // the byte that follows it in the same chunk).
                if b >= 0x20 || b >= 0x80 { line.append(b) }  // printable/UTF-8; other C0 ignored
                out.append(b)
            }
            i += 1
        }
        return out
    }

    func reset() { line = []; inCsi = false; inSs3 = false }
}

// LineTrigger — byte-level input-line tracker at the PTY chokepoint.
// ponytail: no readline emulation — cursor-move sequences (arrows) are
// ignored, so heavy mid-line editing can desync the accumulated text
// from the shell's buffer; ctrl-u always clears the shell side, so the
// worst case is a wrong request string, never a stale executed command.
import Foundation

final class LineTrigger {
    var armed = false
    var onTrigger: ((String) -> Void)?
    private var line: [UInt8] = []
    private static let prefix: [UInt8] = Array("@ai".utf8)

    func filter(_ bytes: [UInt8]) -> [UInt8] {
        guard armed else { line = []; return bytes }
        var out: [UInt8] = []
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            switch b {
            case 0x0D, 0x0A:
                let isTrigger = line.starts(with: Self.prefix) && line.count > Self.prefix.count
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
                if b >= 0x20 || b >= 0x80 { line.append(b) }  // printable/UTF-8; other C0 ignored
                out.append(b)
            }
            i += 1
        }
        return out
    }

    func reset() { line = [] }
}

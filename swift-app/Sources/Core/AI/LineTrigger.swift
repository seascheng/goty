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
    /// Enter swallowed on a zle-edited line (↑/↓/ctrl-r recall): the
    /// line's text lives only on the rendered screen, so the host
    /// reads the cursor row and either fires the task or re-sends the
    /// enter (fail-open, identical to no interception).
    var onPendingEnter: (() -> Void)?
    private var line: [UInt8] = []
    private static let prefix: [UInt8] = Array("@ai".utf8)
    /// Escape-sequence parser state: inside CSI / inside SS3.
    private var inCsi = false
    private var inSs3 = false
    /// This line involved zle editing (arrow keys, ctrl-r search):
    /// the accumulator no longer mirrors the shell's line, so an
    /// enter on it defers to the screen check instead of raw bytes.
    private var zleEdit = false

    func filter(_ bytes: [UInt8]) -> [UInt8] {
        guard armed else { line = []; inCsi = false; inSs3 = false; zleEdit = false; return bytes }
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
                zleEdit = true
                out.append(b)
            case 0x4F where i > 0 && bytes[i - 1] == 0x1B:
                inSs3 = true  // 'O' right after ESC opens SS3
                zleEdit = true
                out.append(b)
            case 0x0D, 0x0A:
                // Paired-symbol IMEs emit '@' as '@@' and may drop the
                // space after the prefix — match the LAST @ai occurrence
                // and let trim handle the rest.
                let isTrigger = Self.hasPrefix(line)
                if ProcessInfo.processInfo.environment["GOTY_AI_DEBUG"] == "1", !line.isEmpty {
                    FileHandle.standardError.write("AILINE armed=\(armed) zle=\(zleEdit) line=\(String(decoding: line.prefix(24), as: UTF8.self)) trigger=\(isTrigger)\n".data(using: .utf8)!)
                }
                if isTrigger {
                    let text = Self.requestText(from: line)
                    line = []; zleEdit = false
                    onTrigger?(text)
                    return out  // swallow this enter (and anything after in the same chunk)
                }
                if zleEdit {
                    // History recall: content is only on the screen.
                    line = []; zleEdit = false
                    onPendingEnter?()
                    return out  // enter (and the rest of the chunk) held for the screen check
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
                line = []; zleEdit = false
                out.append(b)
            case 0x03:  // ctrl-c
                line = []; zleEdit = false
                out.append(b)
            case 0x12:  // ctrl-r (history search) — zle edits the line
                zleEdit = true
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

    func reset() { line = []; inCsi = false; inSs3 = false; zleEdit = false }

    /// Index just after the @ai prefix at the START of the line,
    /// tolerating paired-symbol IMEs that emit '@' as '@@' (each extra
    /// '@' before the final "@ai" is skipped). Mid-line occurrences
    /// never trigger — only line-leading requests do.
    static func lastPrefixEnd(_ line: [UInt8]) -> Int? {
        var i = 0
        // Skip any run of leading '@' — single or doubled alike — then
        // require the literal "ai" right after it.
        while i < line.count && line[i] == 0x40 { i += 1 }
        guard i > 0, i + 2 <= line.count, line[i] == 0x61, line[i + 1] == 0x69
        else { return nil }
        return i + 2
    }

    /// True when the last "@ai" carries at least one non-space byte
    /// after it (a bare '@ai' with nothing typed does not trigger).
    static func hasPrefix(_ line: [UInt8]) -> Bool {
        guard let end = lastPrefixEnd(line) else { return false }
        return line[end...].contains { $0 != 0x20 && $0 != 0x09 }
    }

    /// The request text after the last @ai (surrounding spaces trimmed).
    static func requestText(from line: [UInt8]) -> String {
        guard let end = lastPrefixEnd(line) else { return "" }
        return String(decoding: line[end...], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// @ai request from a RENDERED prompt row (the history-recall
    /// path: ↑/ctrl-r redraws the line as PTY output the input filter
    /// never sees; this reads what the shell actually has). Tolerates
    /// any prompt before the @ — the LAST @ai on the row wins when
    /// something non-space follows and nothing before it quotes,
    /// pipes, or otherwise marks a mid-command occurrence (a recalled
    /// `echo "@ai x"` passes through unchanged). IME "@@" pairs match
    /// via the second @. .whitespaces trims ASCII and full-width
    /// (U+3000) spaces alike — Chinese input needs no special case.
    /// ponytail: prompt-tolerant match can still misfire on a recalled
    /// bare `echo @ai x` (no quotes), ignores wrapped lines and gray
    /// zsh-autosuggestion text; tighten with cursor-column walking
    /// and cell-attribute reads if it bites.
    static func requestFromScreenRow(_ row: String) -> String? {
        let banned: Set<Character> = ["\"", "'", "`", "|", "&", ";", "<", ">", "=", "\\"]
        var hits: [Range<String.Index>] = []
        var search = row.startIndex
        while let r = row.range(of: "@ai", range: search..<row.endIndex) {
            hits.append(r); search = r.upperBound
        }
        for r in hits.reversed() {
            let before = row[row.startIndex..<r.lowerBound]
            guard !before.contains(where: { banned.contains($0) }) else { continue }
            let after = row[r.upperBound..<row.endIndex]
                .trimmingCharacters(in: .whitespaces)
            if !after.isEmpty { return after }
        }
        return nil
    }
}

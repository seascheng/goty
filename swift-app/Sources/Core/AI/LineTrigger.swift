// LineTrigger — byte-level input-line tracker at the PTY chokepoint.
// CSI (ESC [ …0x40–0x7E) and SS3 (ESC O x) sequences pass through to the
// shell but never feed the line accumulator — the trailing letter of an
// arrow key used to land in the buffer (ESC O A → "OA" + "@ai…" never
// matched the prefix and the line fell through to the shell). No
// readline emulation beyond that: text the shell re-edits via arrows can
// still desync — ctrl-u always clears both sides, so the worst case is a
// wrong request string, never a stale executed command.
// Bracketed pastes (ESC[200~ … ESC[201~) forward verbatim: bytes between
// the markers are readline content, so an inner CR/LF is NOT an enter and
// the closing marker is part of the paste, not the chunk's end.
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
    /// Inside a bracketed paste (200~ seen, 201~ pending): every byte
    /// forwards verbatim — no line accumulation, no enter/backspace/
    /// control interpretation. Readline holds the bytes literally.
    private var inPaste = false
    /// The current CSI's bytes from '[' onward, kept only to match the
    /// two bracketed-paste markers exactly.
    private var csi: [UInt8] = []
    /// ESC[200~ / ESC[201~ with the leading ESC dropped — compared
    /// against `csi`, which starts at '['.
    private static let bracketedPasteOn: [UInt8] = Array("[200~".utf8)
    private static let bracketedPasteOff: [UInt8] = Array("[201~".utf8)
    /// This line involved zle editing (arrow keys, ctrl-r search):
    /// the accumulator no longer mirrors the shell's line, so an
    /// enter on it defers to the screen check instead of raw bytes.
    private var zleEdit = false

    func filter(_ bytes: [UInt8]) -> [UInt8] {
        guard armed else { line = []; inCsi = false; inSs3 = false; zleEdit = false; inPaste = false; csi = []; return bytes }
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
                csi.append(b)
                if b >= 0x40 && b <= 0x7E {  // final byte
                    inCsi = false
                    // The bracketed-paste boundaries are ordinary CSI to
                    // the shell but not to this tracker: between them the
                    // bytes are pasted content (verbatim below), and both
                    // markers move the line's truth to the screen — the
                    // first enter after a paste defers to the cursor-row
                    // check like any other re-edited line.
                    if csi == Self.bracketedPasteOn { inPaste = true; zleEdit = true }
                    else if csi == Self.bracketedPasteOff { inPaste = false; zleEdit = true }
                    else { zleEdit = true }
                    csi = []
                }
                out.append(b)
                i += 1
                continue
            }
            // '[' / 'O' right after ESC opens CSI / SS3 — checked before
            // the paste guard so the closing ESC[201~ is recognized even
            // mid-paste.
            if i > 0 && bytes[i - 1] == 0x1B {
                if b == 0x5B {
                    inCsi = true; csi = [b]; zleEdit = true
                    out.append(b)
                    i += 1
                    continue
                }
                if b == 0x4F {
                    inSs3 = true; zleEdit = true
                    out.append(b)
                    i += 1
                    continue
                }
            }
            // Pasted content forwards verbatim. The inner CR/LF used to
            // fall into the enter logic with zleEdit set (the 200~ marker
            // had tripped it), which returned early and dropped the rest
            // of the chunk: every armed multi-line paste arrived as line
            // one only, 201~ closer missing, shell stuck in paste mode.
            if inPaste {
                out.append(b)
                i += 1
                continue
            }
            switch b {
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
                    // Remove the WHOLE UTF-8 character, not one byte:
                    // continuation bytes first, then the LEAD byte they
                    // belong to. Stopping at the lead byte left it
                    // dangling and the next append made the line invalid
                    // UTF-8 → U+FFFD in the card title (the Chinese
                    // mojibake report).
                    while let last = line.last, last & 0xC0 == 0x80,
                          line.count > Self.prefix.count {
                        line.removeLast()
                    }
                    if let last = line.last, last >= 0xC2,
                       line.count > Self.prefix.count {
                        line.removeLast()   // lead of the truncated sequence
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

    func reset() { line = []; inCsi = false; inSs3 = false; zleEdit = false; inPaste = false; csi = [] }

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

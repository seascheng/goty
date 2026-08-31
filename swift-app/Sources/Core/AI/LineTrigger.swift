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
    /// Which line-leading trigger matched.
    enum TriggerKind: Equatable {
        case ai
        /// `@omp` / `@claude` / `@codex` … — an Agent GUI space for
        /// that agent; payload is the manifest key.
        case agent(key: String)
        /// `@tty` — a new terminal tab in this pane's cwd. Takes no
        /// payload; trailing words on the line are ignored.
        case tty
    }

    var armed = false
    /// @ai arms only with the provider configured; the spawn triggers
    /// (@agents, @tty) need just a shell prompt (the fire path handles
    /// a stale daemon itself).
    var agentArmed = false
    var onTrigger: ((String) -> Void)?
    /// `@omp [prompt]` — a new Agent GUI space in this pane's cwd.
    var onAgentTrigger: ((String, String) -> Void)?
    /// `@tty` — a new terminal tab in this pane's cwd.
    var onTTYTrigger: (() -> Void)?
    /// Enter swallowed on a zle-edited line (↑/↓/ctrl-r recall): the
    /// line's text lives only on the rendered screen, so the host
    /// reads the cursor row and either fires the task or re-sends the
    /// enter (fail-open, identical to no interception).
    var onPendingEnter: (() -> Void)?
    private var line: [UInt8] = []
    private static let prefixes: [(bytes: [UInt8], kind: TriggerKind)] = {
        var list: [(bytes: [UInt8], kind: TriggerKind)] = [(Array("@ai".utf8), .ai)]
        for descriptor in AgentRegistry.descriptors {
            list.append((Array("@\(descriptor.key)".utf8), .agent(key: descriptor.key)))
        }
        list.append((Array("@tty".utf8), .tty))
        return list
    }()
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
        guard armed || agentArmed else {
            line = []; inCsi = false; inSs3 = false; zleEdit = false; inPaste = false; csi = []; return bytes
        }
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
                // space after the prefix — match the LAST occurrence
                // and let trim handle the rest.
                let match = Self.classify(line)
                if ProcessInfo.processInfo.environment["GOTY_AI_DEBUG"] == "1", !line.isEmpty {
                    FileHandle.standardError.write("AILINE armed=\(armed) agent=\(agentArmed) zle=\(zleEdit) line=\(String(decoding: line.prefix(24), as: UTF8.self)) trigger=\(match != nil)\n".data(using: .utf8)!)
                }
                if let match, (match.kind == .ai ? armed : agentArmed) {
                    line = []; zleEdit = false
                    switch match.kind {
                    case .ai: onTrigger?(match.text)
                    case .agent(let key): onAgentTrigger?(key, match.text)
                    case .tty: onTTYTrigger?()   // payload-less by design
                    }
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
                // Clamp at the matched trigger prefix: backspacing into
                // "@ai"/"@omp" would silently disarm the trigger — while
                // the line IS exactly a prefix, the delete is dropped
                // (the shell still sees the backspace byte). Any other
                // line deletes freely.
                let matchedPrefixCount = Self.prefixes.first {
                    line.count == $0.bytes.count && line.elementsEqual($0.bytes)
                }?.bytes.count ?? 0
                if line.count > matchedPrefixCount {
                    line.removeLast()
                    // Remove the WHOLE UTF-8 character, not one byte:
                    // continuation bytes first, then the LEAD byte they
                    // belong to (the Chinese mojibake report).
                    while let last = line.last, last & 0xC0 == 0x80,
                          line.count > matchedPrefixCount {
                        line.removeLast()
                    }
                    if let last = line.last, last >= 0xC2,
                       line.count > matchedPrefixCount {
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

    /// A matched trigger: kind + request text after the prefix.
    struct Match {
        let kind: TriggerKind
        let text: String
    }

    /// Classify a line: the LAST line-leading trigger wins (IME "@@"
    /// tolerance). `.ai` needs a request after the prefix (a bare @ai
    /// is meaningless); `.agent` accepts a bare `@omp` — that means
    /// "open the space, no initial prompt".
    static func classify(_ line: [UInt8]) -> Match? {
        for (bytes, kind) in prefixes {
            if hasPrefix(line, prefix: bytes, requirePayload: kind == .ai) {
                return Match(kind: kind, text: requestText(from: line, prefix: bytes))
            }
        }
        return nil
    }

    /// Index just after the trigger prefix at the START of the line,
    /// tolerating paired-symbol IMEs that emit '@' as '@@' (each extra
    /// '@' before the prefix is skipped). Mid-line occurrences never
    /// trigger — only line-leading requests do.
    static func lastPrefixEnd(_ line: [UInt8], prefix: [UInt8] = Array("@ai".utf8)) -> Int? {
        var i = 0
        // Skip any run of leading '@' — single or doubled alike — then
        // require the prefix's remaining bytes right after it.
        while i < line.count && line[i] == 0x40 { i += 1 }
        let stem = prefix.dropFirst()   // prefix's bytes after '@'
        guard i > 0, stem.count > 0, i + stem.count <= line.count,
              Array(line[i..<(i + stem.count)]) == Array(stem)
        else { return nil }
        return i + stem.count
    }

    /// True when the trigger prefix is line-leading and, for `.ai`,
    /// carries at least one non-space byte after it (a bare '@ai' with
    /// nothing typed does not trigger).
    static func hasPrefix(_ line: [UInt8]) -> Bool {
        hasPrefix(line, prefix: Array("@ai".utf8))
    }
    static func hasPrefix(_ line: [UInt8], prefix: [UInt8],
                          requirePayload: Bool = true) -> Bool {
        guard let end = lastPrefixEnd(line, prefix: prefix) else { return false }
        if !requirePayload { return true }
        return line[end...].contains { $0 != 0x20 && $0 != 0x09 }
    }

    /// The request text after the last @ai (surrounding spaces trimmed).
    static func requestText(from line: [UInt8]) -> String {
        requestText(from: line, prefix: Array("@ai".utf8))
    }
    static func requestText(from line: [UInt8], prefix: [UInt8]) -> String {
        guard let end = lastPrefixEnd(line, prefix: prefix) else { return "" }
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
        matchFromScreenRow(row, needle: "@ai", kind: .ai)?.text
    }
    /// One needle's screen-row scan; the LAST hit on the row wins
    /// (same prompt-tolerance rules as the @ai scan). A bare agent
    /// prefix at end-of-row matches with empty text; @ai still needs a
    /// request.
    static func matchFromScreenRow(_ row: String, needle: String,
                                   kind: TriggerKind) -> Match? {
        let banned: Set<Character> = ["\"", "'", "`", "|", "&", ";", "<", ">", "=", "\\"]
        var hits: [Range<String.Index>] = []
        var search = row.startIndex
        while let r = row.range(of: needle, range: search..<row.endIndex) {
            hits.append(r); search = r.upperBound
        }
        for r in hits.reversed() {
            let before = row[row.startIndex..<r.lowerBound]
            guard !before.contains(where: { banned.contains($0) }) else { continue }
            let after = row[r.upperBound..<row.endIndex]
                .trimmingCharacters(in: .whitespaces)
            if !after.isEmpty || kind != .ai {
                return Match(kind: kind, text: after)
            }
        }
        return nil
    }

    /// Screen-row match across every trigger: the rightmost hit on the
    /// row wins, whatever trigger it belongs to.
    static func matchFromScreenRow(_ row: String) -> Match? {
        var best: (at: String.Index, match: Match)?
        for (bytes, kind) in prefixes {
            let needle = String(decoding: bytes, as: UTF8.self)
            guard let m = matchFromScreenRow(row, needle: needle, kind: kind) else { continue }
            // Re-find the rightmost position of this needle that yields
            // the match (the scan above already walks hits backwards).
            if let r = row.range(of: needle, options: .backwards), best == nil || r.lowerBound > best!.at {
                best = (r.lowerBound, m)
            }
        }
        return best?.match
    }
}

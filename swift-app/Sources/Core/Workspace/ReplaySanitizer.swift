import Foundation

// goty — see CLAUDE.md for the working principles.
// Pure byte logic; no AppKit.

/// Strips terminal-query sequences from replayed snapshots.
///
/// The daemon's ring holds everything the shell ever wrote — including
/// the probes a prompt theme sends while drawing (DA1/DA2/DA3, DECRQM,
/// XTWINOPS reports, OSC color queries). Those queries were answered
/// when they first flowed; replaying them through a fresh core makes
/// the parser generate the replies AGAIN, and the io_write path dumps
/// them into the PTY as if the user had typed them — the startup
/// garbage after the first prompt (`62;22;52c2026;2$y…`) on every
/// reattached pane. Replies never appear in PTY output, so any query
/// found in a snapshot is a historical question, not a live one.
///
/// Structure-only scanning: escape sequences are parsed, and anything
/// that is not a query passes through byte-identical — SGR, clear,
/// cursor moves, palette SETS, kitty graphics payloads, plain text,
/// and truncated sequences at the frame edge are all preserved. Live
/// output is never routed through here.
enum ReplaySanitizer {
    /// One snapshot chunk with queries removed.
    static func stripQueries(from data: Data) -> Data {
        var out = Data(); out.reserveCapacity(data.count)
        let bytes = [UInt8](data)
        var i = 0
        let n = bytes.count

        func pass(_ range: Range<Int>) {
            out.append(contentsOf: bytes[range])
        }

        while i < n {
            guard bytes[i] == 0x1b else {   // bulk text: pass to the next ESC
                var j = i
                while j < n, bytes[j] != 0x1b { j += 1 }
                pass(i..<j)
                i = j
                continue
            }
            // CSI: ESC [ params(0x30–0x3F) interm(0x20–0x2F) final(0x40–0x7E)
            if i + 1 < n, bytes[i + 1] == UInt8(ascii: "[") {
                var j = i + 2
                let paramStart = j
                while j < n, (0x30...0x3f).contains(bytes[j]) { j += 1 }
                let params = String(bytes: bytes[paramStart..<j], encoding: .ascii) ?? ""
                let intermStart = j
                while j < n, (0x20...0x2f).contains(bytes[j]) { j += 1 }
                let interm = String(bytes: bytes[intermStart..<j], encoding: .ascii) ?? ""
                guard j < n, (0x40...0x7e).contains(bytes[j]) else {
                    pass(i..<n); return out   // truncated at frame edge — keep
                }
                let final = bytes[j]
                let seq = i..<(j + 1)
                i = j + 1
                if isQueryCSI(params: params, intermediates: interm, final: final) {
                    continue   // drop, replies would regenerate
                }
                pass(seq)
                continue
            }
            // OSC: ESC ] payload (BEL | ESC \)
            if i + 1 < n, bytes[i + 1] == UInt8(ascii: "]") {
                var j = i + 2
                var payloadEnd = j
                while j < n {
                    if bytes[j] == 0x07 { payloadEnd = j; j += 1; break }
                    if bytes[j] == 0x1b, j + 1 < n, bytes[j + 1] == UInt8(ascii: "\\") {
                        payloadEnd = j; j += 2; break
                    }
                    j += 1
                    payloadEnd = j
                }
                if j > n || payloadEnd > j { pass(i..<n); return out }   // truncated — keep
                guard payloadEnd > i + 2 else { pass(i..<j); i = j; continue }
                let payload = String(bytes: bytes[(i + 2)..<payloadEnd],
                                     encoding: .ascii) ?? ""
                let seq = i..<j
                i = j
                if isQueryOSC(payload) { continue }
                pass(seq)
                continue
            }
            // DCS: ESC P payload ESC \ — drop DECRQSS ($q) and XTGETTCAP (+q).
            if i + 1 < n, bytes[i + 1] == UInt8(ascii: "P") {
                var j = i + 2
                while j < n {
                    if bytes[j] == 0x1b, j + 1 < n, bytes[j + 1] == UInt8(ascii: "\\") {
                        j += 2; break
                    }
                    j += 1
                }
                guard j < n else { pass(i..<n); return out }   // truncated — keep
                let head = String(bytes: bytes[(i + 2)..<min(i + 4, j - 2)],
                                  encoding: .ascii) ?? ""
                let seq = i..<j
                i = j
                if head == "$q" || head == "+q" { continue }
                pass(seq)
                continue
            }
            // Any other ESC + byte (two-byte sequences, ST halves).
            if i + 1 < n { pass(i..<(i + 2)); i += 2; continue }
            pass(i..<n); return out
        }
        return out
    }

    /// CSI sequences that make the terminal ANSWER. Parameter grammar is
    /// tight so a coincidental match on real output is not possible:
    /// DA requests carry no parameters beyond their prefix form, DECRQM
    /// is the lone `$p`, XTWINOPS queries are the report selectors, and
    /// `CSI ? u` / `CSI ? c` are the kitty keyboard capability probes.
    private static func isQueryCSI(params: String, intermediates: String,
                                   final: UInt8) -> Bool {
        let f = UnicodeScalar(final)
        // DECRQM: CSI [?] Pm $ p
        if f == "p", intermediates == "$" { return true }
        // Device attributes (DA1/DA2/DA3) — queries; replies (which
        // carry ';' separated numbers) never occur in PTY output.
        if f == "c", intermediates.isEmpty,
           ["", "0", ">", ">0", "=", "=0", "?", "?0"].contains(params) { return true }
        // Kitty keyboard capability probe.
        if f == "u", intermediates.isEmpty, params == "?" { return true }
        // XTWINOPS report selectors (others in the `t` family SET state
        // and stay): pixel/cell/text size 14/16/18, title stack 21/22/23.
        // 16 (cell size, reply `CSI 6;h;wt`) was the missing half of the
        // observed `43;17t…` garbage — the reply body re-typed as input.
        if f == "t", intermediates.isEmpty,
           ["14", "16", "18", "21", "22", "23"].contains(params.split(separator: ";").first.map(String.init)) {
            return true
        }
        return false
    }

    /// OSC sequences that make the terminal answer with a color/palette
    /// report: `10;?`/`11;?`/`110;?`/`111;?`/`112;?` and `4;<idx>;?`.
    /// Sets (`10;#ff0000`) pass through untouched.
    private static func isQueryOSC(_ payload: String) -> Bool {
        let parts = payload.split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        let selector = parts[0]
        let isColorQuery = ["10", "11", "110", "111", "112"].contains(selector)
            && parts[1].hasPrefix("?")
        let isPaletteQuery = selector == "4" && parts.count >= 3 && parts.last == "?"
        return isColorQuery || isPaletteQuery
    }
}

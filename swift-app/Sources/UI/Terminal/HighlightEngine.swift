// goty — see CLAUDE.md for the working principles.
import AppKit

// MARK: - Syntax highlighting (single-pass lexer)
//
// Replaced the vendored tree-sitter engine: 15 grammars compiled to
// ~14 MB of parse tables for a cosmetic feature. This lexer keeps the
// same public surface and the same role palette at KB scale. It is
// dumber than a grammar (no call-vs-decl distinction, regex-free),
// which is the right trade for editor + markdown-fence colorizing.
enum HighlightEngine {
    /// Files past this highlight whole-document only when opened —
    /// same budget the editor itself refuses past 4 MB.
    static let maxBytes = 1_000_000

    static func language(forPath path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        return extensionMap[ext]
    }

    /// Highlight `code` as `language`; nil/unknown language → plain
    /// monochrome attributed string.
    static func highlight(_ code: String, language: String?,
                          font: NSFont, color: NSColor) -> NSAttributedString {
        let plain = NSMutableAttributedString(
            string: code, attributes: [.font: font, .foregroundColor: color])
        let raw = language?.lowercased()
        guard let raw, langs[raw] != nil,
              !code.isEmpty, code.utf8.count <= maxBytes else { return plain }

        let bytes = Array(code.utf8)
        let spans: [(Int, Int, Tok)]
        switch raw {
        case "html": spans = scanHTML(bytes)
        case "yaml": spans = scanYAML(bytes)
        default: spans = scan(bytes, langs[raw]!)
        }
        guard !spans.isEmpty else { return plain }

        // Byte offsets → UTF-16 indices. Spans are sorted and disjoint,
        // so one scalar walk resolves every boundary (no offset map).
        var styled: [(Int, Int, Tok)] = []
        var si = 0
        var open: (start: Int, endByte: Int, tok: Tok)?
        var byte = 0, u16 = 0
        for scalar in code.unicodeScalars {
            if let o = open, o.endByte == byte {
                if u16 > o.start { styled.append((o.start, u16, o.tok)) }
                open = nil
            }
            if open == nil, si < spans.count, spans[si].0 == byte {
                open = (u16, spans[si].1, spans[si].2); si += 1
            }
            byte += UTF8.width(scalar)
            u16 += UTF16.width(scalar)
        }
        if let o = open, o.endByte == byte, u16 > o.start {
            styled.append((o.start, u16, o.tok))
        }

        for (start, end, tok) in styled {
            plain.addAttributes(styleFor(tok).attributes(font: font),
                                range: NSRange(location: start, length: end - start))
        }
        return plain
    }

    // MARK: - Generic scanner

    private enum Tok { case comment, string, number, keyword, call, type,
                          property, attribute, tag, constant }

    private struct Lang {
        var lineComment: [UInt8]? = nil
        var blockComment: ([UInt8], [UInt8])? = nil
        var nestedBlock = false          // swift /* /* */ */
        var singleQuote = false          // '...' is a string (js/py/bash/css)
        var pyStrings = false            // triple-quoted + r""/f"" prefixes
        var keywords: Set<String> = []
        var types: Set<String> = []
        var callHeuristic = true         // ident( → call color
        var uppercaseIsType = true       // Capitalized ident → type color
        var colonKey = false             // ident: → property (css)
        var stringKey = false            // "ident": → property (json)
        var dollarVar = false            // $VAR → constant (bash)
        var atAttribute = false          // swift @word
        var hashKeyword = false          // swift #word
        var atRule = false               // css @word
    }

    private static func scan(_ b: [UInt8], _ lang: Lang) -> [(Int, Int, Tok)] {
        var out: [(Int, Int, Tok)] = []
        let n = b.count
        var i = 0

        func matches(_ i: Int, _ s: [UInt8]) -> Bool {
            i + s.count <= n && Array(b[i..<i + s.count]) == s
        }
        func isIdentStart(_ c: UInt8) -> Bool {
            c == 95 || (65...90).contains(c) || (97...122).contains(c) || c >= 128
        }
        func isIdent(_ c: UInt8) -> Bool { isIdentStart(c) || (48...57).contains(c) }

        func scanString(_ i: Int, _ q: UInt8) -> Int {
            var j = i + 1
            while j < n {
                if b[j] == 92 { j += 2; continue }              // escape
                if b[j] == q { return j + 1 }
                if b[j] == 10 { break }                         // unterminated
                j += 1
            }
            return min(j, n)
        }
        func scanTriple(_ i: Int, _ q: UInt8) -> Int {
            var j = i + 3
            while j + 2 < n {
                if b[j] == 92 { j += 2; continue }
                if b[j] == q && b[j + 1] == q && b[j + 2] == q { return j + 3 }
                j += 1
            }
            return n
        }

        while i < n {
            let c = b[i]
            if let lc = lang.lineComment, matches(i, lc) {
                var j = i
                while j < n && b[j] != 10 { j += 1 }
                out.append((i, j, .comment)); i = j; continue
            }
            if let (bo, bc) = lang.blockComment, matches(i, bo) {
                var j = i + bo.count, depth = 1
                while j < n && depth > 0 {
                    if lang.nestedBlock && matches(j, bo) { depth += 1; j += bo.count; continue }
                    if matches(j, bc) { depth -= 1; j += bc.count; continue }
                    j += 1
                }
                out.append((i, j, .comment)); i = j; continue
            }
            if c == 34 || (lang.singleQuote && c == 39) {
                var start = i
                if lang.pyStrings {
                    if matches(i, [c, c, c]) {
                        let e = scanTriple(i, c)
                        out.append((i, e, .string)); i = e; continue
                    }
                    // r""/f""/rb""… prefix: pull back into the string span
                    var p = i
                    while p > 0 && i - p < 2 && "rfuRFUbU".utf8.contains(b[p - 1]) { p -= 1 }
                    if p > 0 && isIdent(b[p - 1]) { p = i }
                    start = p
                }
                let e = scanString(i, c)
                var tok = Tok.string
                if lang.stringKey {
                    var k = e
                    while k < n && b[k] == 32 { k += 1 }
                    if k < n && b[k] == 58 { tok = .property }   // "key":
                }
                out.append((start, e, tok)); i = e; continue
            }
            if (48...57).contains(c) {
                var j = i + 1
                while j < n {
                    if isIdent(b[j]) || b[j] == 46 { j += 1; continue }
                    if (b[j] == 43 || b[j] == 45) && "eEpP".utf8.contains(b[j - 1]) {
                        j += 1; continue                          // 1e+5
                    }
                    break
                }
                out.append((i, j, .number)); i = j; continue
            }
            if lang.dollarVar && c == 36 {                        // $
                var j = i + 1
                if j < n && b[j] == 123 {                          // {
                    while j < n && b[j] != 125 { j += 1 }
                    j = min(j + 1, n)
                } else {
                    while j < n && isIdent(b[j]) { j += 1 }
                }
                if j > i + 1 { out.append((i, j, .constant)); i = j; continue }
            }
            if (lang.atAttribute || lang.atRule) && c == 64, i + 1 < n, isIdentStart(b[i + 1]) {
                var j = i + 1
                while j < n && isIdent(b[j]) { j += 1 }
                out.append((i, j, lang.atAttribute ? .attribute : .keyword))
                i = j; continue
            }
            if lang.hashKeyword && c == 35, i + 1 < n, isIdentStart(b[i + 1]) {
                var j = i + 1
                while j < n && isIdent(b[j]) { j += 1 }
                out.append((i, j, .keyword)); i = j; continue
            }
            if isIdentStart(c) {
                var j = i + 1
                while j < n && isIdent(b[j]) { j += 1 }
                let word = String(decoding: b[i..<j], as: UTF8.self)
                var tok: Tok?
                if lang.keywords.contains(word) { tok = .keyword }
                else if lang.types.contains(word) { tok = .type }
                if tok == nil {
                    var k = j
                    while k < n && (b[k] == 32 || b[k] == 9) { k += 1 }
                    if k < n {
                        if b[k] == 58 && lang.colonKey { tok = .property }
                        else if b[k] == 40 && lang.callHeuristic { tok = .call }
                    }
                }
                if tok == nil && lang.uppercaseIsType && (65...90).contains(c) { tok = .type }
                if let t = tok { out.append((i, j, t)) }
                i = j; continue
            }
            i += 1
        }
        return out
    }

    // MARK: - HTML scanner (tags / attributes / quoted values)

    private static func scanHTML(_ b: [UInt8]) -> [(Int, Int, Tok)] {
        var out: [(Int, Int, Tok)] = []
        let n = b.count
        var i = 0
        while i < n {
            if i + 3 < n && b[i] == 60 && b[i + 1] == 33 && b[i + 2] == 45 && b[i + 3] == 45 {
                var j = i + 4                              // <!-- -->
                while j + 2 < n && !(b[j] == 45 && b[j + 1] == 45 && b[j + 2] == 62) { j += 1 }
                let e = min(j + 3, n)
                out.append((i, e, .comment)); i = e; continue
            }
            if b[i] == 60 {                                // <tag …>
                var j = i + 1
                if j < n && b[j] == 47 { j += 1 }
                let nameStart = j
                while j < n && (b[j] == 95 || (65...90).contains(b[j]) || (97...122).contains(b[j]) || (48...57).contains(b[j]) || b[j] >= 128) { j += 1 }
                if j > nameStart { out.append((nameStart, j, .tag)) }
                while j < n && b[j] != 62 {                 // until >
                    if b[j] == 34 || b[j] == 39 {
                        let q = b[j]; var e = j + 1
                        while e < n && b[e] != q && b[e] != 10 { e += 1 }
                        e = min(e + 1, n)
                        out.append((j, e, .string)); j = e; continue
                    }
                    if b[j] == 95 || (65...90).contains(b[j]) || (97...122).contains(b[j]) || b[j] >= 128 {
                        let s = j
                        while j < n && (b[j] == 95 || (65...90).contains(b[j]) || (97...122).contains(b[j]) || (48...57).contains(b[j]) || b[j] >= 128) { j += 1 }
                        var k = j
                        while k < n && b[k] == 32 { k += 1 }
                        if k < n && b[k] == 61 { out.append((s, j, .attribute)) }  // attr=
                        continue
                    }
                    j += 1
                }
                i = min(j + 1, n); continue
            }
            i += 1
        }
        return out
    }

    // MARK: - YAML scanner (line keys / strings / comments)

    private static func scanYAML(_ b: [UInt8]) -> [(Int, Int, Tok)] {
        var out: [(Int, Int, Tok)] = []
        let n = b.count
        var i = 0
        while i < n {
            var lineEnd = i
            while lineEnd < n && b[lineEnd] != 10 { lineEnd += 1 }
            var j = i
            while j < lineEnd && b[j] == 32 { j += 1 }
            if j < lineEnd && b[j] == 45 && j + 1 < lineEnd && b[j + 1] == 32 { j += 2 }
            while j < lineEnd && b[j] == 32 { j += 1 }
            // key (quoted or bare) terminated by ':' + space/EOL
            let kStart = j
            var k = j
            if k < lineEnd && (b[k] == 34 || b[k] == 39) {
                let q = b[k]; k += 1
                while k < lineEnd && b[k] != q { if b[k] == 92 { k += 1 }; k += 1 }
                k = min(k + 1, lineEnd)
            } else {
                while k < lineEnd && b[k] != 58 && b[k] != 35 { k += 1 }
            }
            var m = k
            while m < lineEnd && b[m] == 32 { m += 1 }
            if k > kStart && m < lineEnd && b[m] == 58 && (m + 1 >= lineEnd || b[m + 1] == 32) {
                out.append((kStart, k, .property))
                j = m + 1
            } else {
                j = kStart
            }
            while j < lineEnd {                             // value part
                if b[j] == 34 || b[j] == 39 {
                    let q = b[j]; var e = j + 1
                    while e < lineEnd && b[e] != q { if b[e] == 92 { e += 1 }; e += 1 }
                    e = min(e + 1, lineEnd)
                    out.append((j, e, .string)); j = e; continue
                }
                if b[j] == 35 { out.append((j, lineEnd, .comment)); break }
                j += 1
            }
            i = lineEnd + 1
        }
        return out
    }

    // MARK: - Language table

    private static let langs: [String: Lang] = {
        func kw(_ s: String) -> Set<String> { Set(s.split(separator: " ").map(String.init)) }
        let slash = [UInt8](arrayLiteral: 47, 47)            // //
        let hash = [UInt8](arrayLiteral: 35)                 // #
        let cBlock: ([UInt8], [UInt8]) = ([47, 42], [42, 47]) // /* */
        var m: [String: Lang] = [:]
        m["swift"] = Lang(lineComment: slash, blockComment: cBlock, nestedBlock: true,
            keywords: kw("associatedtype actor any as async await break case catch class continue convenience default defer deinit didSet do else enum extension fallthrough false final for func guard if import in indirect infix init inout internal is lazy let nil nonisolated open operator override postfix precedencegroup prefix private protocol public repeat required rethrows return self Self some static struct subscript super switch throw throws true try typealias var weak where while willSet"),
            types: kw("Bool Character Double Float Int Int8 Int16 Int32 Int64 Never Optional String UInt Void"))
        m["rust"] = Lang(lineComment: slash, blockComment: cBlock,
            keywords: kw("as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type union unsafe use where while"),
            types: kw("bool char str i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 String Vec Option Result Some None Ok Err Box Rc Arc"))
        m["typescript"] = Lang(lineComment: slash, blockComment: cBlock, singleQuote: true,
            keywords: kw("abstract as async await break case catch class const continue debugger declare default delete do else enum export extends false finally for from function get if implements import in infer instanceof interface is keyof let namespace new null of private protected public readonly return satisfies set static super switch this throw true try type typeof undefined var void while with yield"),
            types: kw("any never unknown string number boolean object symbol bigint"))
        m["javascript"] = m["typescript"]!
        m["python"] = Lang(lineComment: hash, singleQuote: true, pyStrings: true,
            keywords: kw("and as assert async await break class continue def del elif else except False finally for from global if import in is lambda match case None nonlocal not or pass raise return True try while with yield self"),
            types: kw("int float str bool list dict set tuple bytes object type print"))
        m["c"] = Lang(lineComment: slash, blockComment: cBlock,
            keywords: kw("auto break case const continue default do else enum extern for goto if inline return sizeof static struct switch typedef union void volatile while NULL true false"),
            types: kw("bool char double float int long short signed unsigned size_t ssize_t uint8_t uint16_t uint32_t uint64_t int8_t int16_t int32_t int64_t"))
        var cpp = m["c"]!
        cpp.keywords.formUnion(kw("alignas alignof and class compl concept consteval constexpr constinit const_cast co_await co_return co_yield decltype delete dynamic_cast explicit export friend mutable namespace new noexcept not nullptr operator or private protected public reinterpret_cast requires static_assert static_cast template this thread_local throw try typeid typename using virtual xor override final"))
        cpp.types.formUnion(kw("string vector map set pair array unique_ptr shared_ptr"))
        m["cpp"] = cpp
        m["go"] = Lang(lineComment: slash, blockComment: cBlock,
            keywords: kw("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var nil true false iota make new len cap append copy delete panic recover"),
            types: kw("bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr"))
        m["java"] = Lang(lineComment: slash, blockComment: cBlock,
            keywords: kw("abstract assert break byte case catch char class const continue default do double else enum extends final finally float for goto if implements import instanceof int interface long native new package private protected public record return short static strictfp super switch synchronized this throw throws transient try var void volatile while true false null sealed permits yield"),
            types: kw("Boolean Byte Character Double Float Integer Long Short String Object List Map Set"))
        m["bash"] = Lang(lineComment: hash, singleQuote: true,
            keywords: kw("if then else elif fi for while until do done case esac function in select time coproc return break continue local export readonly declare unset shift source alias trap exit set"),
            uppercaseIsType: false, dollarVar: true)
        m["json"] = Lang(
            keywords: kw("true false null"),
            callHeuristic: false, uppercaseIsType: false, stringKey: true)
        m["css"] = Lang(blockComment: cBlock, singleQuote: true,
            keywords: kw("and from important keyframes media not only screen print all supports to"),
            callHeuristic: false, uppercaseIsType: false, colonKey: true, atRule: true)
        m["yaml"] = Lang(lineComment: hash,
            keywords: kw("true false null yes no on off"),
            callHeuristic: false, uppercaseIsType: false)
        m["html"] = Lang()
        return m
    }()

    /// Fence info strings arrive in wild spellings; canonicalize the
    /// common ones onto the table above.
    private static let aliases: [String: String] = [
        "sh": "bash", "zsh": "bash", "shell": "bash", "console": "bash",
        "shell-session": "bash", "sh-session": "bash", "bash-session": "bash",
        "dockerfile": "bash", "py": "python", "golang": "go",
        "typescriptreact": "typescript", "javascriptreact": "javascript",
        "c++": "cpp", "objective-c": "c", "objc": "c",
    ]

    private static let extensionMap: [String: String] = [
        "swift": "swift", "rs": "rust",
        "ts": "typescript", "tsx": "typescript", "mts": "typescript", "cts": "typescript",
        "js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript",
        "py": "python", "pyi": "python",
        "c": "c", "h": "c",
        "cpp": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp", "ipp": "cpp",
        "json": "json", "jsonc": "json",
        "sh": "bash", "bash": "bash", "zsh": "bash",
        "css": "css", "scss": "css",
        "html": "html", "htm": "html",
        "yaml": "yaml", "yml": "yaml",
        "go": "go", "java": "java",
    ]

    // MARK: - Theme (token kinds → colors)

    private struct Style {
        let color: NSColor
        let bold: Bool
        let italic: Bool

        func attributes(font: NSFont) -> [NSAttributedString.Key: Any] {
            var f = font
            if bold || italic {
                var traits: NSFontTraitMask = []
                if bold { traits.insert(.boldFontMask) }
                if italic { traits.insert(.italicFontMask) }
                f = NSFontManager.shared.convert(font, toHaveTrait: traits)
            }
            return [.font: f, .foregroundColor: color]
        }
    }

    private static func styleFor(_ tok: Tok) -> Style {
        switch tok {
        case .comment: return Style(color: palette.comment, bold: false, italic: true)
        case .keyword, .constant: return Style(color: palette.keyword, bold: false, italic: false)
        case .string: return Style(color: palette.string, bold: false, italic: false)
        case .call: return Style(color: palette.function, bold: false, italic: false)
        case .type: return Style(color: palette.type, bold: false, italic: false)
        case .number: return Style(color: palette.constant, bold: false, italic: false)
        case .property: return Style(color: palette.property, bold: false, italic: false)
        case .tag: return Style(color: palette.tag, bold: false, italic: false)
        case .attribute: return Style(color: palette.attribute, bold: false, italic: false)
        }
    }

    /// Helix-style default dark ramp — the same role set every editor
    /// theme carries; colors sit on Chrome's surfaces.
    private struct Palette {
        let keyword: NSColor
        let string: NSColor
        let function: NSColor
        let type: NSColor
        let constant: NSColor
        let property: NSColor
        let comment: NSColor
        let tag: NSColor
        let attribute: NSColor
    }

    private static var palette: Palette {
        Palette(
            keyword: NSColor(calibratedRed: 0.75, green: 0.44, blue: 0.85, alpha: 1),
            string: NSColor(calibratedRed: 0.55, green: 0.80, blue: 0.53, alpha: 1),
            function: NSColor(calibratedRed: 0.42, green: 0.66, blue: 0.93, alpha: 1),
            type: NSColor(calibratedRed: 0.90, green: 0.78, blue: 0.35, alpha: 1),
            constant: NSColor(calibratedRed: 0.43, green: 0.79, blue: 0.78, alpha: 1),
            property: NSColor(calibratedRed: 0.55, green: 0.60, blue: 0.86, alpha: 1),
            comment: NSColor(calibratedWhite: 0.45, alpha: 1),
            tag: NSColor(calibratedRed: 0.55, green: 0.70, blue: 0.90, alpha: 1),
            attribute: NSColor(calibratedRed: 0.85, green: 0.62, blue: 0.45, alpha: 1))
    }
}

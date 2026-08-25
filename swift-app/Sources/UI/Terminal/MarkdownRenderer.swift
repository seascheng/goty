// goty — see CLAUDE.md for the working principles.
import AppKit
import CcmarkGfm

/// Block decorations the PREVIEW view paints (TextKit runs can only
/// paint behind glyphs; the view fills block geometry edge-to-edge).
extension NSAttributedString.Key {
    static let mdCodeBlock = NSAttributedString.Key("goty.md.codeBlock")
    static let mdQuote = NSAttributedString.Key("goty.md.quote")
}
private typealias NodeType = cmark_node_type

// Tasklist items carry a RUNTIME-allocated node type (extension), not a
// compile-time constant — resolved once after registration.

// MARK: - Markdown renderer (cmark-gfm engine, tty7 division of labor)

/// Markdown rendering with a MATURE ENGINE: cmark-gfm (GitHub's CommonMark
/// + GFM extensions: tables, tasklists, strikethrough) does all parsing —
/// exactly tty7's split, where pulldown-cmark parses and gpui-component
/// only styles. We walk the AST and map nodes onto theme typography;
/// fenced code goes through the highlight engine.
///
/// The old hand-rolled line parser is gone (it drifted: markers leaked
/// into visible text, nested lists were wrong, tables impossible).
enum MarkdownRenderer {
    /// `highlight` renders fenced code blocks through tree-sitter
    /// (nil → plain mono). Returns a themed, ready-to-display string.
    static func render(_ markdown: String,
                       bodySize: CGFloat = 12.5,
                       highlight: ((String, String?) -> NSAttributedString)? = nil)
        -> NSAttributedString {
        cmark_gfm_core_extensions_ensure_registered()
        // Parse WITH the GFM extensions attached (tables, tasklists,
        // strikethrough, autolinks) — registering alone ignores them.
        guard let data = markdown.data(using: .utf8),
              let doc = data.withUnsafeBytes({ raw -> OpaquePointer? in
                  let parser = cmark_parser_new(CMARK_OPT_DEFAULT)
                  for name in ["table", "tasklist", "strikethrough", "autolink"] {
                      if let ext = cmark_find_syntax_extension(name) {
                          cmark_parser_attach_syntax_extension(parser, ext)
                      }
                  }
                  cmark_parser_feed(parser,
                                    raw.baseAddress?.assumingMemoryBound(to: CChar.self),
                                    raw.count)
                  let parsed = cmark_parser_finish(parser)
                  cmark_parser_free(parser)
                  return parsed
              })
        else {
            return NSAttributedString(string: markdown)
        }
        defer { cmark_node_free(doc) }

        let style = MdStyle(bodySize: bodySize)
        let out = MdWriter(style: style, highlight: highlight)
        out.walk(doc)
        return out.result
    }
}

/// Typography ladder + theme tokens for the renderer. The ladder IS
/// gpui-component's markdown defaults (what tty7 renders with):
/// body 14px, headings 2 / 1.5 / 1.25 / 1.125 / 1 / 1 rem × 14px,
/// paragraph gap 1rem, code one step under body. Numbers in one place;
/// the AST decides structure, this decides looks.
private struct MdStyle {
    let body: NSFont
    let mono: NSFont
    let bold: NSFont
    let italic: NSFont
    let fg: NSColor
    let muted: NSColor
    let codeBG: NSColor
    let accent: NSColor

    /// `bodySize` stays the caller's zoom knob, but the DEFAULT layout
    /// (EditorPanel) passes tty7's 14.
    init(bodySize: CGFloat) {
        body = .systemFont(ofSize: bodySize)
        mono = .monospacedSystemFont(ofSize: bodySize - 1.5, weight: .regular)
        bold = NSFontManager.shared.convert(body, toHaveTrait: .boldFontMask)
        italic = NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask)
        fg = Chrome.theme.foreground
        muted = Chrome.theme.secondaryText
        codeBG = Chrome.theme.topBarBackground
        accent = NSColor.controlAccentColor
    }

    /// Vertical rhythm — the ladder the header comment promises, made
    /// real (gpui-component markdown: body line-height 1.5, paragraph
    /// gap ~0.75em, list items tighter; headings breathe before,
    /// settle after). Before 2026-08-24 paragraphs carried NO style at
    /// all: blocks were separated by a bare "\n" (zero gap) and body
    /// ran at the font's own cramped line height.
    var lineGap: CGFloat { body.pointSize * 0.32 }
    var paraGap: CGFloat { body.pointSize * 0.72 }
    var itemGap: CGFloat { body.pointSize * 0.28 }

    func bodyPara() -> NSParagraphStyle {
        para(spacing: paraGap, lineSpacing: lineGap)
    }

    func headingPara(_ level: Int32) -> NSParagraphStyle {
        let lv = Int(max(1, min(6, level)))
        let before = body.pointSize * (lv == 1 ? 0.55 : lv == 2 ? 0.45 : 0.35)
        return para(spacing: body.pointSize * 0.3, before: before, lineSpacing: lineGap)
    }

    /// List item: marker outdented to `base`, wrapped lines hang at
    /// `base + 18` (the style must own the WHOLE item paragraph —
    /// TextKit takes a paragraph's style from its first character).
    func listItemPara(depth: Int) -> NSParagraphStyle {
        let base = 18 * CGFloat(max(0, depth - 1))
        return para(spacing: itemGap, head: base + 18, lineSpacing: lineGap, hanging: base)
    }

    func rulePara() -> NSParagraphStyle {
        para(spacing: body.pointSize * 0.6, lineSpacing: 2)
    }

    /// bold/semibold/semibold/semibold/semibold/medium.
    func heading(_ level: Int32) -> (NSFont, NSColor) {
        let sizes: [CGFloat] = [14, 7, 3.5, 2, 0, 0]
        let weights: [NSFont.Weight] = [.bold, .semibold, .semibold, .semibold, .semibold, .medium]
        let lv = Int(max(1, min(6, level)))
        return (NSFont.systemFont(ofSize: body.pointSize + sizes[lv - 1],
                                  weight: weights[lv - 1]),
                fg)
    }

    func para(spacing: CGFloat, head: CGFloat = 0, before: CGFloat = 0,
              lineSpacing: CGFloat = 2, tail: CGFloat = 0,
              wrap: NSLineBreakMode = .byWordWrapping,
              hanging: CGFloat? = nil) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = spacing
        p.paragraphSpacingBefore = before
        p.lineSpacing = lineSpacing
        p.lineBreakMode = wrap
        p.headIndent = head
        p.firstLineHeadIndent = hanging ?? head
        p.tailIndent = tail
        return p
    }
}

/// Single pass over the cmark AST building the output. Block state is a
/// stack of paragraph styles; inline state is a font/color tuple the
/// emphasis/code/link nodes refine.
private final class MdWriter {
    let style: MdStyle
    let highlight: ((String, String?) -> NSAttributedString)?
    var result = NSMutableAttributedString()

    /// Inline context: fonts/colors pushed by emph/strong/code/link.
    private var inlineFont: NSFont
    private var inlineColor: NSColor
    private var linkURL: String?
    /// Where the current link's text began (its run ends at exit).
    private var linkStart = 0
    /// Heading context: text nodes take the heading font while set.
    private var headingLevel: Int32 = 0
    private var quoteDepth = 0
    /// Where the outermost open quote began (result offset).
    private var quoteStart: Int?
    private var strike = false

    /// Block-exit styling: every block records where it began and gets
    /// its paragraph style applied over the WHOLE range on exit
    /// (TextKit reads a paragraph's style from its first character —
    /// styles dabbed onto marker tails never took).
    private var paraStart: Int?
    private var itemStart: Int?
    private var listDepth = 0
    private var orderedStack: [(start: Int32, counter: Int32)] = []

    /// While inside a table, inline text is buffered into cells
    /// (`sink` redirects append) and emitted as NSTextTable blocks on
    /// the table's exit — tty7's bordered grid.
    private var tableRows: [[NSMutableAttributedString]]?

    /// Table cells receive every inline append while a table is open.
    private var sink: NSMutableAttributedString {
        if let lastRow = tableRows?.last, let cell = lastRow.last { return cell }
        return result
    }

    init(style: MdStyle, highlight: ((String, String?) -> NSAttributedString)?) {
        self.style = style
        self.highlight = highlight
        inlineFont = style.body
        inlineColor = style.fg
    }

    func walk(_ root: OpaquePointer) {
        // Manual recursion keeps exit-event styling simple and lets
        // tables/rows/cells (children of custom nodes) fall through to
        // the generic path.
        var child = cmark_node_first_child(root)
        while let node = child {
            emit(node, entering: true)
            walk(node)
            emit(node, entering: false)
            child = cmark_node_next(node)
        }
    }

    private func type(_ n: OpaquePointer) -> NodeType { cmark_node_get_type(n) }

    private func lit(_ n: OpaquePointer) -> String {
        cmark_node_get_literal(n).map { String(cString: $0) } ?? ""
    }

    private func append(_ s: String, _ attrs: [NSAttributedString.Key: Any]) {
        sink.append(NSAttributedString(string: s, attributes: attrs))
    }

    private func newline() {
        append("\n", [.font: style.body, .foregroundColor: style.fg])
    }

    /// Block terminator: ONE newline at most. A list item's inner
    /// paragraph already ends the line — a second \n here was the
    /// blank line between every pair of items (report 2026-08-24).
    private func terminateBlock() {
        guard result.length > 0 else { return }
        let ns = result.string as NSString
        if ns.character(at: result.length - 1) != 0x0A { newline() }
    }


    func emit(_ node: OpaquePointer, entering: Bool) {
        let t = type(node)
        switch t {
        case CMARK_NODE_DOCUMENT:
            break

        case CMARK_NODE_HEADING:
            if entering {
                headingLevel = cmark_node_get_heading_level(node)
                paraStart = result.length
            } else {
                terminateBlock()
                if let s = paraStart, result.length > s {
                    result.addAttribute(.paragraphStyle, value: style.headingPara(headingLevel),
                                        range: NSRange(location: s, length: result.length - s))
                }
                paraStart = nil
                headingLevel = 0
            }

        case CMARK_NODE_PARAGRAPH:
            // No inline quote prefix — the view paints the quote bar
            // (mdQuote), so wrapped lines carry no stray glyphs.
            if entering {
                paraStart = result.length
            } else {
                terminateBlock()
                if let s = paraStart, result.length > s {
                    result.addAttribute(.paragraphStyle, value: style.bodyPara(),
                                        range: NSRange(location: s, length: result.length - s))
                }
                paraStart = nil
            }

        case CMARK_NODE_PARAGRAPH:
            // No inline quote prefix — the view paints the quote bar
            // (mdQuote), so wrapped lines carry no stray glyphs.
            if entering {
                paraStart = result.length
            } else {
                newline()
                if let s = paraStart, result.length > s {
                    result.addAttribute(.paragraphStyle, value: style.bodyPara(),
                                        range: NSRange(location: s, length: result.length - s))
                }
                paraStart = nil
            }

        case CMARK_NODE_TEXT:
            if entering { append(lit(node), attrs()) }

        case CMARK_NODE_SOFTBREAK:
            if entering { append(" ", attrs()) }

        case CMARK_NODE_LINEBREAK:
            if entering { newline() }

        case CMARK_NODE_EMPH:
            if entering { inlineFont = NSFontManager.shared.convert(inlineFont,
                                                                   toHaveTrait: .italicFontMask) }
            else { inlineFont = style.body }

        case CMARK_NODE_STRIKETHROUGH:
            strike = entering
        case CMARK_NODE_STRONG:
            if entering { inlineFont = NSFontManager.shared.convert(inlineFont,
                                                                   toHaveTrait: .boldFontMask) }
            else { inlineFont = style.body }

        case CMARK_NODE_CODE:
            if entering {
                append(lit(node), [
                    .font: style.mono,
                    .foregroundColor: inlineColor,
                    .backgroundColor: style.codeBG,
                ])
            }

        case CMARK_NODE_LINK:
            if entering {
                linkURL = cmark_node_get_url(node).map { String(cString: $0) }
                // The link's own run starts here; before this fix the
                // attribute landed on the WHOLE document, every time.
                linkStart = result.length
                inlineColor = style.accent
            } else {
                let range = NSRange(location: linkStart, length: result.length - linkStart)
                if let url = linkURL, let target = URL(string: url) {
                    result.addAttribute(.link, value: target, range: range)
                }
                result.addAttribute(.underlineStyle,
                                    value: NSUnderlineStyle.single.rawValue, range: range)
                inlineColor = style.fg
                linkURL = nil
            }

        case CMARK_NODE_BLOCK_QUOTE:
            // tty7: muted content with a left bar. The bar itself is a
            // view-painted mdQuote decoration; paragraphs shift right
            // so text clears it (nested quotes shift once per level).
            if entering {
                quoteDepth += 1
                if quoteStart == nil { quoteStart = result.length }
                inlineColor = style.muted
            } else {
                quoteDepth -= 1
                inlineColor = style.fg
                if quoteDepth <= 0 {
                    quoteDepth = 0
                    if let start = quoteStart {
                        quoteStart = nil
                        decorateQuote(NSRange(location: start, length: result.length - start))
                    }
                }
            }

        case CMARK_NODE_LIST:
            if entering {
                listDepth += 1
                if cmark_node_get_list_type(node) == CMARK_ORDERED_LIST {
                    orderedStack.append((cmark_node_get_list_start(node), 0))
                }
            } else {
                listDepth -= 1
                if cmark_node_get_list_type(node) == CMARK_ORDERED_LIST {
                    orderedStack.removeLast()
                }
            }

        case CMARK_NODE_ITEM:
            if entering {
                itemStart = result.length
                // Tasklist items are plain ITEMs carrying the tasklist
                // syntax extension (its type string overrides "item").
                let typeString = String(cString: cmark_node_get_type_string(node))
                let isTasklist = typeString == "tasklist"
                if isTasklist {
                    append(cmark_gfm_extensions_get_tasklist_item_checked(node)
                            ? "☑  " : "☐  ",
                           [.font: style.body, .foregroundColor: style.muted])
                } else if var ordered = orderedStack.last {
                    ordered.counter += 1
                    orderedStack[orderedStack.count - 1] = ordered
                    append("\(ordered.counter). ",
                           [.font: style.body, .foregroundColor: style.muted])
                } else {
                    append("•  ", [.font: style.body, .foregroundColor: style.muted])
                }
            } else {
                // Style owns the WHOLE item paragraph (marker included)
                // so the hanging indent actually applies — the old
                // 1-char dab on the marker tail never did.
                terminateBlock()
                if let s = itemStart, result.length > s {
                    result.addAttribute(.paragraphStyle,
                                        value: style.listItemPara(depth: listDepth),
                                        range: NSRange(location: s, length: result.length - s))
                }
                itemStart = nil
            }

        case CMARK_NODE_CODE_BLOCK:
            // Whole-block literal, rendered once on ENTER; its spacing
            // rides the paragraph style (appendMarked).
            if entering {
                let code = lit(node)
                let info = String(cString: cmark_node_get_fence_info(node))
                    .trimmingCharacters(in: .whitespaces)
                let lang = info.split(separator: " ").first.map(String.init)
                if let highlight {
                    appendMarked(highlight(code, lang))
                } else {
                    appendMarked(NSAttributedString(
                        string: code,
                        attributes: [.font: style.mono, .foregroundColor: style.fg]))
                }
                newline()
            }

        case CMARK_NODE_THEMATIC_BREAK:
            if entering {
                let ruleStart = result.length
                append("──────────────────────────────",
                       [.font: style.body, .foregroundColor: style.muted])
                newline()
                result.addAttribute(.paragraphStyle, value: style.rulePara(),
                                    range: NSRange(location: ruleStart,
                                                   length: result.length - ruleStart))
            }

        case CMARK_NODE_HTML_BLOCK, CMARK_NODE_HTML_INLINE:
            break   // no web pane; html is not rendered

        case CMARK_NODE_TABLE:
            // tty7: a bordered grid. Cells buffer inline content
            // (append redirects via sink); the exit turns the buffer
            // into NSTextTable blocks — TextKit's real table layout.
            if entering {
                tableRows = [[]]
            } else {
                emitTable()
            }

        case CMARK_NODE_TABLE_ROW:
            if entering { tableRows?.append([]) }

        case CMARK_NODE_TABLE_CELL:
            if entering {
                if let rowCount = tableRows?.count, rowCount > 0 {
                    tableRows?[rowCount - 1].append(NSMutableAttributedString())
                }
                if cmark_gfm_extensions_get_table_row_is_header(
                    cmark_node_parent(node)) != 0 {
                    inlineFont = style.bold
                }
            } else {
                // Cell separator: one paragraph per cell is what fills
                // the table row by row.
                newline()
                inlineFont = style.body
            }
        default:
            break
        }
    }

    private func attrs() -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [.font: inlineFont,
                                                .foregroundColor: inlineColor]
        if headingLevel > 0 {
            let (font, color) = style.heading(headingLevel)
            a[.font] = font
            a[.foregroundColor] = color
        }
        if strike { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return a
    }

    /// Highlight results carry their own attributes; re-paragraphed and
    /// marked for the view's full-width background (run-level bg can
    /// only paint behind glyphs).
    private func appendMarked(_ block: NSAttributedString) {
        let full = NSRange(location: 0, length: block.length)
        let m = NSMutableAttributedString(attributedString: block)
        // The block's own rhythm: breathes around itself like every
        // other block, one line-gap between code lines.
        m.addAttribute(.paragraphStyle,
                       value: style.para(spacing: style.paraGap * 0.7,
                                         head: 8,
                                         before: style.paraGap * 0.7,
                                         lineSpacing: 3,
                                         tail: -8, wrap: .byCharWrapping),
                       range: full)
        m.addAttribute(.mdCodeBlock, value: true, range: full)
        result.append(m)
    }

    /// Quote decoration: bar attribute over the whole block, plus a
    /// uniform indent shift of every paragraph inside (list hanging
    /// indents keep their shape — both edges move).
    private func decorateQuote(_ range: NSRange) {
        guard range.length > 0 else { return }
        result.addAttribute(.mdQuote, value: true, range: range)
        var restyled: [(NSRange, NSParagraphStyle)] = []
        result.enumerateAttribute(.paragraphStyle, in: range) { value, run, _ in
            let base = (value as? NSParagraphStyle)?.mutableCopy()
                as? NSMutableParagraphStyle
                ?? style.bodyPara().mutableCopy() as! NSMutableParagraphStyle
            base.headIndent += 20
            base.firstLineHeadIndent += 20
            restyled.append((run, base))
        }
        for (run, para) in restyled {
            result.addAttribute(.paragraphStyle, value: para, range: run)
        }
    }

    /// The buffered cells become one NSTextTable: TextKit's own table
    /// layout (columns auto-proportioned, cells wrap) — the same
    /// bordered-grid shape tty7 renders.
    private func emitTable() {
        defer { tableRows = nil }
        guard let rows = tableRows, !rows.isEmpty else { return }
        let cols = rows.map(\.count).max() ?? 0
        guard cols > 0 else { return }
        let table = NSTextTable()
        table.numberOfColumns = cols
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        let lastRow = rows.count - 1
        for (r, row) in rows.enumerated() {
            for c in 0..<cols {
                let cell = c < row.count ? row[c]
                    : NSMutableAttributedString(string: "\n",
                                                attributes: [.font: style.body])
                let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1,
                                              startingColumn: c, columnSpan: 1)
                // Convenience forms: one hairline border on every edge.
                block.setBorderColor(Chrome.theme.hairline)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                if r == 0 { block.backgroundColor = Chrome.theme.markdownBlockBackground }
                let para = NSMutableParagraphStyle()
                // No spacing INSIDE the grid (rows would drift apart);
                // the table breathes via its first/last cell's spacing.
                para.lineSpacing = 2
                para.textBlocks = [block]
                if r == 0, c == 0 { para.paragraphSpacingBefore = style.paraGap * 0.7 }
                if r == lastRow, c == cols - 1 { para.paragraphSpacing = style.paraGap * 0.7 }
                cell.addAttribute(.paragraphStyle, value: para,
                                  range: NSRange(location: 0, length: cell.length))
                result.append(cell)
            }
        }
        // One paragraph OUTSIDE the table closes it; otherwise the
        // following block's first paragraph is swallowed as a cell.
        newline()
    }
}

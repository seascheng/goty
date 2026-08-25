// goty — see CLAUDE.md for the working principles.
import AppKit

// MARK: - Markdown preview text view (block decorations)

/// The renderer marks code blocks and quotes as ATTRIBUTES; TextKit
/// runs can only paint behind glyphs, so this view fills the block
/// geometry edge-to-edge instead (full-width code backgrounds, quote
/// bars) — the tty7 gpui-component block look.
final class MarkdownPreviewTextView: NSTextView {
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let lm = layoutManager, let container = textContainer, let storage = textStorage
        else { return }
        let origin = textContainerOrigin
        let probe = NSRect(x: rect.minX - origin.x, y: rect.minY - origin.y,
                           width: rect.width, height: rect.height)
        let visibleGlyphs = lm.glyphRange(forBoundingRect: probe, in: container)
        guard visibleGlyphs.length > 0 else { return }
        let visibleChars = lm.characterRange(forGlyphRange: visibleGlyphs,
                                             actualGlyphRange: nil)

        storage.enumerateAttribute(.mdCodeBlock, in: visibleChars) { marked, range, _ in
            guard marked != nil else { return }
            // The block surface token — a step clearly above the page
            // (topBarBackground's 5% lift read as nothing).
            Chrome.theme.markdownBlockBackground.setFill()
            paintFragments(of: range, in: lm, origin: origin) { frag in
                // Vertical bleed closes the gaps paragraph spacing
                // opens between a block's fragments.
                NSRect(x: -origin.x, y: frag.minY + origin.y - 2,
                       width: bounds.width, height: frag.height + 4).fill()
            }
        }
        storage.enumerateAttribute(.mdQuote, in: visibleChars) { marked, range, _ in
            guard marked != nil else { return }
            Chrome.theme.hairline.setFill()
            paintFragments(of: range, in: lm, origin: origin) { frag in
                NSRect(x: 8, y: frag.minY + origin.y, width: 3, height: frag.height).fill()
            }
        }
    }

    /// Fragment rects of `charRange`, painted by `paint`.
    private func paintFragments(of charRange: NSRange, in lm: NSLayoutManager,
                                origin: NSPoint, paint: (NSRect) -> Void) {
        let glyphRange = lm.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return }
        var glyph = glyphRange.location
        while glyph < NSMaxRange(glyphRange) {
            var frag = NSRange()
            let fragRect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &frag,
                                               withoutAdditionalLayout: true)
            if frag.location < NSMaxRange(glyphRange), NSMaxRange(frag) > glyphRange.location {
                paint(fragRect)
            }
            glyph = NSMaxRange(frag)
        }
    }
}

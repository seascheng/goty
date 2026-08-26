// goty — see CLAUDE.md for the working principles.
import AppKit

final class FileListContainer: NSView {
    override var isFlipped: Bool { true }

    /// Rows in TREE order (what setRows last laid out). A resize
    /// re-frames THESE, not `subviews`: kept rows keep their old
    /// z-position while inserted rows append at the end, so a height
    /// change mid-expand used to re-lay the list in z-order — expanded
    /// children dropped below every older row the moment the document
    /// grew past the clip view.
    private var orderedRows: [NSView] = []

    func setRows(_ rows: [(key: String, view: NSView)]) {
        var existing: [String: NSView] = [:]
        for row in subviews {
            if let keyed = row as? KeyedRow { existing[keyed.rowKey] = row }
        }
        // Drop rows whose key vanished; keep order from the caller.
        let wanted = Set(rows.map({ $0.key }))
        for row in subviews {
            if let keyed = row as? KeyedRow, !wanted.contains(keyed.rowKey) {
                row.removeFromSuperview()
            }
        }
        var y: CGFloat = 0
        var ordered: [NSView] = []
        for (key, candidate) in rows {
            // Same key: keep the LIVE instance (state survives), just
            // re-frame it. Different view for the same key (a header
            // replacing a row) swaps in.
            let row: NSView
            if let live = existing[key], type(of: live) == type(of: candidate) {
                candidate.removeFromSuperview()
                row = live
            } else {
                row = candidate
                if row.superview !== self { addSubview(row) }
            }
            let h = (row as? KeyedRow)?.rowHeight ?? 26
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
            y += h
            ordered.append(row)
        }
        orderedRows = ordered
        setFrameSize(NSSize(width: bounds.width,
                            height: max(y, superview?.bounds.height ?? 0)))
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        var y: CGFloat = 0
        for row in orderedRows {
            let h = (row as? KeyedRow)?.rowHeight ?? 26
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
            y += h
        }
    }
}

/// Identity for row reconciliation. `rowHeight` is the row's height
/// for the container's manual layout — a row taller than the 26pt
/// default (e.g. the two-line worktree row) reports it here, or the
/// container crushes it and its text overflows the row.
@objc protocol KeyedRow: NSObjectProtocol {
    var rowKey: String { get }
    @objc optional var rowHeight: CGFloat { get }
}


/// One 26pt tree row: tty7 lucide glyph (folder / folder-open / file),
/// name, indent by depth (tty7 geometry: 13pt glyph, 12.5pt label).

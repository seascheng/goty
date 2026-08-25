// goty — see CLAUDE.md for the working principles.
import AppKit

final class FileRow: NSView, KeyedRow {
    var onOpen: (() -> Void)?
    /// Reconciliation identity: the row's absolute path.
    var rowKey: String { dragPath ?? entry.name }
    var onToggle: (() -> Void)?
    var onContext: ((NSView) -> Void)?
    /// Finder drop → upload into this row's directory (folder row: the
    /// folder itself; file row: its parent — "next to this file"). Set
    /// only by a remote FilesView; nil rows are no drop destination.
    var onDrop: (([URL]) -> Bool)?
    /// Intra-tree drop (move): the directory this row stands for.
    var onTreeDrop: (([String]) -> Void)?
    /// Drag this row's absolute path (tty7 rows drag as external
    /// paths). Local sources also advertise a file URL so Finder
    /// accepts a drag out of the tree.
    var dragPath: String?
    var isLocalDrag = false
    private var pressPoint: NSPoint?
    private var dropIsMove = false
    private var isDropTarget = false
    let entry: FileEntry
    private let depth: Int
    private let isOpen: Bool

    init(entry: FileEntry, depth: Int, expanded: Bool,
         badge: (letter: String, color: NSColor)? = nil,
         glyphTint: NSColor? = nil) {
        self.entry = entry
        self.depth = depth
        self.isOpen = expanded
        super.init(frame: .zero)

        // tty7: no disclosure chevron — the folder glyph itself carries the
        // open/closed state (folder-open / folder), files take the lucide
        // file glyph; the icon column keeps every level's names aligned.
        let glyph = LucideIconView(
            entry.isDirectory ? (expanded ? .folderOpen : .folder) : .file,
            pointSize: 13,
            tint: glyphTint
                ?? (entry.isDirectory ? Chrome.theme.foreground
                                     : Chrome.theme.secondaryText))
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)

        let label = NSTextField(labelWithString: entry.name)
        label.font = .systemFont(ofSize: 12.5, weight: .regular)
        label.textColor = Chrome.theme.foreground
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.truncatesLastVisibleLine = true
        label.cell?.wraps = false
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        // tty7 geometry: 6+depth·14 inset, glyph 13, 4pt gap to the label.
        let inset: CGFloat = 10 + CGFloat(depth) * 14
        var labelTrailing: NSLayoutConstraint!

        // The same 14pt badge cell the SCM rows use (tty7 BADGE_W), so
        // a file reads identically in the tree and the panel.
        if let badge {
            let badgeField = NSTextField(labelWithString: badge.letter)
            badgeField.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
            badgeField.textColor = badge.color
            badgeField.alignment = .center
            badgeField.translatesAutoresizingMaskIntoConstraints = false
            addSubview(badgeField)
            NSLayoutConstraint.activate([
                badgeField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                badgeField.centerYAnchor.constraint(equalTo: centerYAnchor),
                badgeField.widthAnchor.constraint(equalToConstant: 14),
            ])
            labelTrailing = label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -26)
        } else {
            labelTrailing = label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 13),
            glyph.heightAnchor.constraint(equalToConstant: 13),
            label.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 4),
            labelTrailing,
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways,
                                                              .mouseEnteredAndExited],
                                       owner: self, userInfo: nil))
        addGestureRecognizer(ActionClickRecognizer { [weak self] in self?.onOpen?() })
        // Both drag flavors: intra-tree (move) and Finder/external
        // (upload for remote trees; ignored for local rows, where the
        // empty-space target handles Finder drops into the root).
        registerForDraggedTypes([FilesView.treePathsType, .fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if Self.treeDragPaths(sender) != nil, onTreeDrop != nil {
            dropIsMove = true
            isDropTarget = true
            needsDisplay = true
            return .move
        }
        dropIsMove = false
        guard onDrop != nil, FilesView.dragURLs(sender) != nil else { return [] }
        isDropTarget = true
        needsDisplay = true
        return .copy
    }

    /// Paths dragged from this tree (nil = a Finder/external drag).
    static func treeDragPaths(_ sender: NSDraggingInfo) -> [String]? {
        guard let items = sender.draggingPasteboard.pasteboardItems,
              items.contains(where: { $0.string(forType: FilesView.treePathsType) != nil }) else { return nil }
        return items.compactMap { $0.string(forType: FilesView.treePathsType) }
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTarget = false
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTarget = false
        needsDisplay = true
        if dropIsMove, let paths = FileRow.treeDragPaths(sender) {
            // A modal (replace-confirm) or disk work inside a drag
            // callback re-enters AppKit's drag machinery — defer.
            let drop = onTreeDrop
            DispatchQueue.main.async { drop?(paths) }
            return true
        }
        guard let onDrop, let urls = FilesView.dragURLs(sender) else { return false }
        return onDrop(urls)
    }

    required init?(coder: NSCoder) { fatalError("init(coder: not implemented") }

    override func mouseDown(with event: NSEvent) {
        pressPoint = event.locationInWindow
        super.mouseDown(with: event)
    }

    /// The dragging session's `source` is NOT retained by AppKit; the
    /// decoration poll rebuilds every row mid-drag, and a rebuilt row
    /// leaves the session pointing at a zombie. Self-retain for the
    /// session's lifetime.
    private var sessionKeepAlive: FileRow?

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        guard let start = pressPoint, let path = dragPath else { return }
        let here = event.locationInWindow
        guard abs(here.x - start.x) + abs(here.y - start.y) > 6 else { return }
        pressPoint = nil   // one session per press; clicks stay clicks
        let item = NSPasteboardItem()
        item.setString(path, forType: FilesView.treePathsType)
        if isLocalDrag {
            // Plain path string — the type's documented payload. Raw
            // UTF-8 bytes made the pasteboard a malformed file URL.
            item.setString(path, forType: .fileURL)
        }
        sessionKeepAlive = self
        // A dragging item WITHOUT image components makes
        // beginDraggingSession throw (documented) — the drag crash.
        // The component is a live snapshot of the row: the ghost that
        // follows the cursor, tty7's drag look.
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.draggingFrame = NSRect(origin: .zero, size: bounds.size)
        dragItem.imageComponentsProvider = { [weak self] in
            guard let self,
                  let rep = self.bitmapImageRepForCachingDisplay(in: self.bounds)
            else { return [] }
            self.cacheDisplay(in: self.bounds, to: rep)
            let image = NSImage()
            image.addRepresentation(rep)
            let component = NSDraggingImageComponent(key: .label)
            component.contents = image
            component.frame = NSRect(origin: .zero, size: self.bounds.size)
            return [component]
        }
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    override func rightMouseDown(with event: NSEvent) {
        onContext?(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isDropTarget {
            Chrome.theme.selectionPill.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 1),
                         xRadius: 6, yRadius: 6).fill()
        } else if isHovered {
            Chrome.theme.hoverFill.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 1),
                         xRadius: 6, yRadius: 6).fill()
        }
    }

    private var isHovered = false
    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }
}

extension FileRow: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        DispatchQueue.main.async { [weak self] in
            self?.sessionKeepAlive = nil
        }
    }
}

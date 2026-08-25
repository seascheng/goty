// goty — see CLAUDE.md for the working principles.
import AppKit

final class CreationRow: NSView, KeyedRow {
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    /// Reconciliation identity ("create:<dir>" / "rename:<path>").
    var rowKey: String { "edit:" + (editingPath ?? creatingDir) }
    var editingPath: String?
    var creatingDir: String = ""
    private var isFinished = false
    /// When beginEditing claimed focus. An empty-field resign inside the
    /// first second after takeover is focus churn (menu teardown, field
    /// editor races), not the user finishing — the row must survive it.
    fileprivate var activatedAt = Date.distantPast
    /// TRUE only after the USER typed (controlTextDidChange). A resign
    /// without edits is NEVER a commit — it is focus being stolen, and
    /// the row re-claims instead of resolving. Explicit acts (Return,
    /// Escape, a real click elsewhere) are the only endings.
    fileprivate var userEdited = false
    fileprivate var originalText = ""
    fileprivate var reclaimAttempts = 0

    private let field = CreationField()
    private var clickCommitMonitor: Any?

    init(isDirectory: Bool, depth: Int,
         initialText: String = "", placeholder: String? = nil) {
        originalText = initialText
        super.init(frame: .zero)

        let glyph = LucideIconView(
            isDirectory ? .folder : .file,
            pointSize: 13,
            tint: Chrome.theme.secondaryText)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)

        field.placeholderString = placeholder ?? (isDirectory ? "folder name" : "file name")
        field.stringValue = initialText
        field.font = .systemFont(ofSize: 12.5, weight: .regular)
        field.textColor = Chrome.theme.foreground
        field.backgroundColor = Chrome.theme.hoverFill
        field.focusRingType = .none
        field.bezelStyle = .roundedBezel
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)

        // Same column as a real row at this depth (chevron column is gone).
        let inset: CGFloat = 10 + CGFloat(depth) * 14
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 13),
            glyph.heightAnchor.constraint(equalToConstant: 13),
            field.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder: not implemented") }

    func beginEditing() {
        // Claim focus AFTER the context menu's teardown restores the
        // pre-menu first responder (the terminal surface): claiming in
        // the same turn loses the race, the field resigns instantly,
        // and the row flashes away before a keystroke lands. The small
        // delay also skips spurious textDidEndEditing noise from fields
        // that never really became first responder.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, !self.isFinished else { return }
            self.activatedAt = Date()
            // GOTY_HEADLESS: the headless behavior harness has no window
            // server focus, where AppKit's field-editor takeover is
            // nondeterministic; row survival and the commit path are
            // what it asserts.
            if ProcessInfo.processInfo.environment["GOTY_HEADLESS"] == nil {
                self.window?.makeFirstResponder(self.field)
                self.field.selectText(nil)
                self.installClickCommitMonitor()
            }
        }
    }

    /// Commit when the user clicks anywhere outside the field. The hit
    /// test is point-IN-RECT (a point-vs-origin comparison fired on the
    /// very click into the field, committing an empty name).
    private func installClickCommitMonitor() {
        clickCommitMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return event }
            if event.window === self.window {
                let fieldRect = self.convert(self.field.bounds, to: nil)
                if !fieldRect.contains(event.locationInWindow) {
                    self.finish(commit: self.userEdited)
                }
            }
            return event
        }
    }

    /// Test surface (headless menu harness).
    func typeForTest(_ text: String) { field.stringValue = text }
    func simulateSpuriousResignForTest() { fieldResigned(reason: nil) }
    var fieldTextForTest: String { field.stringValue }
    func commitForTest() { finish(commit: true) }

    /// Enter or focus loss. Only EXPLICIT acts resolve the edit:
    /// Return commits; anything else without user edits is a steal —
    /// re-claim the focus and stay editing (bounded attempts; a user
    /// who switched apps entirely gets the row back on click).
    func fieldResigned(reason: String?) {
        guard !isFinished else { return }
        if reason == "pressReturn" {
            finish(commit: true)
            return
        }
        if userEdited {
            finish(commit: true)
            return
        }
        // Spurious: re-claim.
        guard reclaimAttempts < 3 else { return }
        reclaimAttempts += 1
        let field = self.field
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, !self.isFinished,
                  self.field.stringValue == self.originalText || self.userEdited
            else { return }
            if self.window?.firstResponder !== field.currentEditor() {
                self.window?.makeFirstResponder(field)
                if field.currentEditor() != nil { self.reclaimAttempts = 0 }
            }
        }
    }

    fileprivate func userEditedDidChange() {
        userEdited = true
        reclaimAttempts = 0
    }

    func finish(commit: Bool) {
        if let monitor = clickCommitMonitor {
            NSEvent.removeMonitor(monitor)
            clickCommitMonitor = nil
        }
        // textDidEndEditing fires again when the field resigns after a
        // monitor commit — idempotent or the op runs twice.
        guard !isFinished else { return }
        isFinished = true
        if commit {
            onCommit?(field.stringValue)
        } else {
            onCancel?()
        }
    }

}

/// Escape cancels; Enter/focus-loss commits (sidebar rename semantics).
/// A resign only counts once the field truly held focus — the takeover
/// attempts that fail (non-key windows, menu teardown races) must not
/// read as "user finished typing".

private final class CreationField: NSTextField {
    private(set) var heldFocus = false

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { heldFocus = true }
        return ok
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            (superview as? CreationRow)?.finish(commit: false)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        (superview as? CreationRow)?.userEditedDidChange()
    }

    override func textDidEndEditing(_ notification: Notification) {
        // NOT super — the default forwards control notifications we
        // resolve ourselves.
        let reason = notification.userInfo?["NSTextDidEndEditingReason"] as? String
        (superview as? CreationRow)?.fieldResigned(reason: reason)
    }
}
/// The scroll view sets its width; row frames are computed here.
/// Rows are RECONCILED BY KEY, not rebuilt: an unchanged key keeps its
 /// live view instance, so first responders (rename/creation fields),
/// drag sessions, and hover state survive every re-render BY
/// CONSTRUCTION — the whole class of "background refresh killed my
/// edit" bugs (2026-08-23).

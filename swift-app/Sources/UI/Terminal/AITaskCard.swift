// goty — see CLAUDE.md for the working principles.
import AppKit

// MARK: - AI task card (bottom-anchored pane overlay)

/// Rounds, proposals, and results for one running AITask — an overlay
/// ABOVE the terminal surface, never text written into the Ghostty
/// buffer. The card never becomes firstResponder outside its input and
/// edit modes, so arrow keys keep reaching the terminal.
// MARK: - markdown box (shared control: answers render markdown, stay
// selectable, and scroll instead of clipping)

/// Selectable, non-editable text box that renders markdown via the
/// editor's renderer and reports its laid-out height as intrinsic —
/// the stack grows with content up to `maxHeight`, beyond which the
/// box scrolls internally (the fixed-height clamp used to silently
/// eat long answers).
final class AIMarkdownBox: NSView {
    private let textView = NSTextView()
    private let scroll = NSScrollView()
    var maxHeight: CGFloat = 240

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = chromeSurface(Chrome.theme.markdownBlockBackground).cgColor

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 8
        textView.defaultParagraphStyle = {
            let p = NSMutableParagraphStyle()
            p.lineBreakMode = .byWordWrapping
            return p
        }()

        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = textView
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func setMarkdown(_ markdown: String) {
        textView.textStorage?.setAttributedString(MarkdownRenderer.render(
            markdown, bodySize: 12.5,
            highlight: { code, lang in
                HighlightEngine.highlight(
                    code, language: lang,
                    font: .monospacedSystemFont(ofSize: 11.5, weight: .regular),
                    color: Chrome.theme.foreground)
            }))
        invalidateIntrinsicContentSize()
    }

    func setPlainText(_ text: String, font: NSFont) {
        textView.textColor = Chrome.theme.foreground
        textView.font = font
        textView.string = text
        invalidateIntrinsicContentSize()
    }

    var textViewSelectableForTest: Bool { textView.isSelectable }

    override var intrinsicContentSize: NSSize {
        let container = textView.textContainer ?? NSTextContainer()
        let used = textView.layoutManager?.usedRect(for: container).height ?? 0
        return NSSize(width: NSView.noIntrinsicMetric,
                      height: min(maxHeight, ceil(used) + 10))
    }

    override func layout() {
        super.layout()
        // Width comes from the stack; keep the container tracking so the
        // text re-wraps and the intrinsic height stays honest.
        let clipWidth = (scroll.contentView as? NSClipView)?.bounds.width ?? bounds.width
        textView.textContainer?.size = NSSize(width: max(clipWidth, 40),
                                              height: .greatestFiniteMagnitude)
        invalidateIntrinsicContentSize()
    }
}

// MARK: - small NSView helper

extension NSView {
    /// Depth-first search for the first descendant of the given type
    /// (stack-nested cards etc.).
    func firstSubviewOfType<T: NSView>(_ type: T.Type) -> T? {
        for v in subviews {
            if let hit = v as? T { return hit }
            if let hit = v.firstSubviewOfType(type) { return hit }
        }
        return nil
    }
}

// MARK: - card

final class AITaskCard: NSView {
    var onConfirm: (() -> Void)?
    var onEdit: ((AIProposal) -> Void)?
    var onCancel: (() -> Void)?
    var onContinue: (() -> Void)?
    var onClose: (() -> Void)?
    /// Fill terminal: emits the proposal's command; the host appends the
    /// trailing space and sends it as plain input (never auto-runs).
    var onFill: ((String) -> Void)?
    /// Input mode (⌘⇧A): Enter submits the typed request.
    var onSubmit: ((String) -> Void)?

    private let stack = NSStackView()
    private var inputMode = false
    private var editMode = false
    private var editingProposal: AIProposal?
    /// Last bash command seen in a proposal/execution — the Fill
    /// terminal target after completion.
    private var lastBashCommand: String?
    /// Full transcript of the rendered task — the Copy button source.
    private var lastTranscript: String?
    private var inputField: ChromeInput?

    /// Transcript for Copy: every round's tool + result, then the
    /// summary. Mono, plain text — pastes cleanly anywhere.
    static func transcript(rounds: [AIRound], summary: String) -> String {
        var lines = rounds.map { r in
            "[\(r.toolName ?? "tool")] \(r.toolInput)\n\(r.toolResult)"
        }
        lines.append(summary)
        return lines.joined(separator: "\n\n")
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = ControlMetrics.radius + 2
        layer?.borderWidth = 1
        layer?.borderColor = Chrome.theme.hairline.cgColor
        layer?.backgroundColor = chromeSurface(Chrome.theme.topBarBackground).cgColor

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // MARK: modes

    /// ⌘⇧A: an empty card with a request field. Submitting follows the
    /// exact @ai path (PaneHost routes onSubmit to onAITask).
    func enterInputMode(target: ExecutionTarget?) {
        inputMode = true
        editMode = false
        rebuild { group in
            group.header(target: target, phase: "Ask AI")
            let field = ChromeInput(placeholder: "Ask the model to do what, where?")
            field.onReturn = { [weak self] in self?.submitInput() }
            field.onEscape = { [weak self] in self?.onClose?() }
            self.inputField = field
            group.add(field)
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        }
        window?.makeFirstResponder(inputField)
    }

    private func submitInput() {
        guard let text = inputField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }
        inputMode = false
        onSubmit?(text)
    }

    // MARK: render

    func render(task: AITask, target: ExecutionTarget) {
        guard !inputMode else { return }   // typed request wins until submitted
        if editMode { renderEdit(task: task, target: target); return }
        switch task.phase {
        case .idle, .thinking:
            rebuild { group in
                group.header(target: target, phase: "thinking…")
                group.rounds(task.rounds)
            }
        case .awaitingConfirmation:
            if let proposal = task.pendingProposal {
                if case .bash(let command) = proposal.op { lastBashCommand = command }
                rebuild { group in
                    group.header(target: target, phase: "confirmation required")
                    group.rounds(task.rounds)
                    group.proposal(proposal, target: target)
                    group.buttons {
                        $0.add("Execute", proposal.risk == .destructive ? .danger : .primary) {
                            [weak self] in self?.onConfirm?()
                        }
                        $0.add("Edit", .ghost) { [weak self] in
                            self?.editMode = true
                            self?.editingProposal = proposal
                            self?.renderEdit(task: task, target: target)
                        }
                        $0.add("Cancel", .ghost) { [weak self] in self?.onCancel?() }
                    }
                }
            }
        case .budgetExhausted(let progress):
            rebuild { group in
                group.header(target: target, phase: "round budget exhausted")
                group.rounds(task.rounds)
                group.label("25 rounds used. \(progress)",
                            font: .systemFont(ofSize: 12), color: Chrome.theme.secondaryText)
                group.buttons {
                    $0.add("Continue +25", .primary) { [weak self] in self?.onContinue?() }
                    $0.add("Propose", .ghost) { [weak self] in
                        self?.editMode = false
                        self?.enterInputMode(target: target)
                    }
                    $0.add("Cancel", .ghost) { [weak self] in self?.onCancel?() }
                }
            }
        case .executing:
            if case .bash(let command)? = task.pendingProposal?.op { lastBashCommand = command }
            rebuild { group in
                group.header(target: target, phase: "executing…")
                group.rounds(task.rounds)
            }
        case .completed(let summary):
            lastTranscript = Self.transcript(rounds: task.rounds, summary: summary)
            rebuild { group in
                group.header(target: target, phase: "done")
                group.rounds(task.rounds)
                _ = group.markdown(summary)
                group.buttons {
                    $0.add("Copy", .ghost) { [weak self] in
                        guard let text = self?.lastTranscript else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    $0.add("Fill terminal", .ghost) { [weak self] in
                        guard let cmd = self?.lastBashCommand else { return }
                        self?.onFill?(cmd)
                    }
                    $0.add("Close", .ghost) { [weak self] in self?.onClose?() }
                }
            }
        case .failed(let message):
            lastTranscript = message
            rebuild { group in
                group.header(target: target, phase: "failed")
                _ = group.markdown(message)
                group.buttons {
                    $0.add("Copy", .ghost) { [weak self] in
                        guard let text = self?.lastTranscript else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    $0.add("Close", .ghost) { [weak self] in self?.onClose?() }
                }
            }
        case .cancelled:
            rebuild { group in
                group.header(target: target, phase: "cancelled")
                group.buttons {
                    $0.add("Close", .ghost) { [weak self] in self?.onClose?() }
                }
            }
        }
    }

    // MARK: edit mode

    private func renderEdit(task: AITask, target: ExecutionTarget) {
        guard let proposal = editingProposal ?? task.pendingProposal else { return }
        editingProposal = proposal
        rebuild { group in
            group.header(target: target, phase: "edit proposal")
            switch proposal.op {
            case .bash(let command):
                group.editField(label: "command", text: command, tag: 1)
            case .write(let path, let content):
                group.editField(label: "path", text: path, tag: 1)
                group.editBlock(label: "content", text: content, tag: 2)
            case .edit(let path, let oldText, let newText):
                group.editField(label: "path", text: path, tag: 1)
                group.editBlock(label: "old (anchor)", text: oldText, tag: 2)
                group.editBlock(label: "new", text: newText, tag: 3)
            }
            group.buttons {
                $0.add("Save", .primary) { [weak self] in self?.saveEdit(proposal) }
                $0.add("Back", .ghost) { [weak self] in
                    self?.editMode = false
                    self?.render(task: task, target: target)
                }
            }
        }
        if let editor = editorFor(tag: 1) { window?.makeFirstResponder(editor) }
    }

    /// Parse the fields back to a proposal of the SAME op kind; an
    /// invalid or empty edit keeps the card in edit mode.
    private func saveEdit(_ original: AIProposal) {
        let next: AIProposal.Op?
        switch original.op {
        case .bash:
            let command = (editorFor(tag: 1) as? NSTextView)?.string
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            next = command.isEmpty ? nil : .bash(command)
        case .write:
            let path = (editorFor(tag: 1) as? NSTextView)?.string.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let content = (editorFor(tag: 2) as? NSTextView)?.string ?? ""
            next = path.isEmpty ? nil : .write(path: path, content: content)
        case .edit(_, let oldText, _):
            let path = (editorFor(tag: 1) as? NSTextView)?.string.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let old = (editorFor(tag: 2) as? NSTextView)?.string ?? oldText
            let new = (editorFor(tag: 3) as? NSTextView)?.string ?? ""
            next = (path.isEmpty || new.isEmpty) ? nil
                : .edit(path: path, oldText: old, newText: new)
        }
        guard let op = next else { return }   // invalid → stays in edit
        editMode = false
        editingProposal = nil
        onEdit?(AIProposal(op: op, explanation: original.explanation,
                           risk: original.risk, rollbackHint: original.rollbackHint))
        // The coordinator emits a fresh snapshot; until then keep the
        // card consistent by clearing the stale body.
        rebuild { group in group.label("Updated — confirm to execute.",
                                       font: .systemFont(ofSize: 12),
                                       color: Chrome.theme.secondaryText) }
    }

    private func editorFor(tag: Int) -> NSView? {
        let key = NSUserInterfaceItemIdentifier("goty.ai.edit\(tag)")
        return stack.views.first { $0.identifier == key }
    }

    // MARK: content builders

    /// One rebuild pass: clears the stack, hands the group builder the
    /// section helpers, all wired to this card's stack.
    // MARK: test surface

    func renderForTest(markdown: String) {
        rebuild { group in _ = group.markdown(markdown) }
    }
    var isTextViewSelectableForTest: Bool {
        firstSubviewOfType(AIMarkdownBox.self)?.textViewSelectableForTest ?? false
    }

    private func rebuild(_ build: (Group) -> Void) {
        for view in stack.views { stack.removeView(view) }
        inputField = nil
        build(Group(card: self))
    }

    /// Section helpers scoped to one rebuild. Views keep default tag 0;
    /// edit-mode editors carry their parse tag.
    struct Group {
        let card: AITaskCard
        private var stack: NSStackView { card.stack }

        func header(target: ExecutionTarget?, phase: String) {
            let name = target?.displayName ?? "Local"
            let cwd = target?.cwd ?? "~"
            let title = name + " · " + cwd
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            row.addView(label(title, font: .systemFont(ofSize: 12, weight: .semibold),
                              color: Chrome.theme.foreground), in: .leading)
            row.addView(label("AI · \(phase)", font: .systemFont(ofSize: 11),
                              color: Chrome.theme.secondaryText), in: .leading)
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            row.addView(spacer, in: .leading)
            add(views: [row])
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }

        func rounds(_ rounds: [AIRound]) {
            guard !rounds.isEmpty else { return }
            for round in rounds.suffix(6) {
                let name = round.toolName ?? "tool"
                let line = "› \(name)  \(round.toolResult)"
                add(views: [mono(line)])
            }
            if rounds.count > 6 {
                add(views: [label("+\(rounds.count - 6) more rounds",
                                  font: .systemFont(ofSize: 11),
                                  color: Chrome.theme.secondaryText)])
            }
        }

        func proposal(_ proposal: AIProposal, target: ExecutionTarget) {
            let explanation = proposal.explanation
            if !explanation.isEmpty {
                _ = markdown(explanation)
            }
            switch proposal.op {
            case .bash(let command):
                _ = monoSelectable(command)
            case .write(let path, let content):
                add(views: [mono("write \(path)"),
                            block(content, tint: nil)])
            case .edit(let path, let oldText, let newText):
                add(views: [mono("edit \(path)"),
                            block("- " + oldText, tint: Chrome.theme.gitRemoved),
                            block("+ " + newText, tint: Chrome.theme.gitAdded)])
            }
            let riskLine: (String, NSColor)
            switch proposal.risk {
            case .destructive:
                riskLine = ("⚠ destructive — runs on \(target.displayName)",
                            Chrome.theme.dangerText)
            case .mutating:
                riskLine = ("mutating — runs on \(target.displayName)",
                            NSColor(hex: "#F59E0B") ?? .systemOrange)
            case .readOnly:
                riskLine = ("read-only — runs on \(target.displayName)",
                            Chrome.theme.secondaryText)
            }
            add(views: [label(riskLine.0, font: .systemFont(ofSize: 11, weight: .medium),
                              color: riskLine.1)])
            if let rollback = proposal.rollbackHint, !rollback.isEmpty {
                add(views: [label("undo: \(rollback)", font: .systemFont(ofSize: 11),
                                  color: Chrome.theme.secondaryText)])
            }
        }

        func buttons(_ build: (ButtonRow) -> Void) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            add(views: [row])
            build(ButtonRow(row: row))
        }

        struct ButtonRow {
            let row: NSStackView
            func add(_ title: String, _ style: ChromeButton.Style,
                     action: @escaping () -> Void) {
                row.addView(ChromeButton.make(title, style: style, onClick: action),
                            in: .leading)
            }
        }

        @discardableResult
        func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.font = font
            field.textColor = color
            field.lineBreakMode = .byWordWrapping
            add(views: [field])
            field.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor,
                                         constant: -24).isActive = true
            return field
        }

        /// Markdown-rendered, selectable, internally scrolling text
        /// (answers and explanations — LLMs speak markdown).
        func markdown(_ text: String) -> AIMarkdownBox {
            let box = AIMarkdownBox(frame: .zero)
            box.setMarkdown(text)
            add(views: [box])
            box.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor,
                                       constant: -24).isActive = true
            return box
        }

        /// Selectable mono text (tool output, transcripts).
        func monoSelectable(_ text: String) -> AIMarkdownBox {
            let box = AIMarkdownBox(frame: .zero)
            box.maxHeight = 140
            box.setPlainText(text, font: .monospacedSystemFont(ofSize: 11.5, weight: .regular))
            add(views: [box])
            box.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor,
                                       constant: -24).isActive = true
            return box
        }

        func mono(_ text: String) -> NSTextField {
            label(text, font: .monospacedSystemFont(ofSize: 11.5, weight: .regular),
                  color: Chrome.theme.foreground)
        }

        /// Multi-line mono block (write content / edit old-new), tinted.
        private func block(_ text: String, tint: NSColor?) -> NSView {
            let view = NSTextField(labelWithString: text)
            view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            view.textColor = tint ?? Chrome.theme.foreground
            view.lineBreakMode = .byTruncatingTail
            view.maximumNumberOfLines = 8
            add(views: [view])
            view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor,
                                        constant: -24).isActive = true
            return view
        }

        /// Edit-mode single-line editor (identified for Save parsing).
        func editField(label name: String, text: String, tag: Int) {
            add(views: [label(name, font: .systemFont(ofSize: 11),
                              color: Chrome.theme.secondaryText)])
            let editor = monoEditor(text: text)
            editor.identifier = NSUserInterfaceItemIdentifier("goty.ai.edit\(tag)")
            add(views: [editor])
            editor.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor,
                                          constant: -24).isActive = true
        }

        /// Edit-mode multi-line editor (identified for Save parsing).
        func editBlock(label name: String, text: String, tag: Int) {
            add(views: [label(name, font: .systemFont(ofSize: 11),
                              color: Chrome.theme.secondaryText)])
            let editor = monoEditor(text: text, multiline: true)
            editor.identifier = NSUserInterfaceItemIdentifier("goty.ai.edit\(tag)")
            add(views: [editor])
            editor.heightAnchor.constraint(equalToConstant: 96).isActive = true
            editor.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor,
                                          constant: -24).isActive = true
        }

        private func monoEditor(text: String, multiline: Bool = false) -> NSTextView {
            let storage = NSTextStorage(string: text)
            let container = NSTextContainer(
                size: NSSize(width: 0, height: multiline
                    ? CGFloat.greatestFiniteMagnitude : 22))
            container.widthTracksTextView = true
            container.heightTracksTextView = multiline
            let layout = NSLayoutManager()
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            let editor = NSTextView(frame: .zero, textContainer: container)
            editor.isRichText = false
            editor.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            editor.drawsBackground = false
            editor.backgroundColor = .clear
            editor.focusRingType = .none
            editor.isVerticallyResizable = multiline
            editor.translatesAutoresizingMaskIntoConstraints = false
            return editor
        }

        /// One view directly into the stack (input field etc.).
        func add(_ view: NSView) { stack.addView(view, in: .leading) }
        func add(views: [NSView]) {
            for view in views { stack.addView(view, in: .leading) }
        }
    }
}

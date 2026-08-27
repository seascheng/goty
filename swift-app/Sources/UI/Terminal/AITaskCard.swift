// goty — see CLAUDE.md for the working principles.
import AppKit

// MARK: - AI task card (bottom-anchored pane overlay)

/// Rounds, proposals, and results for one running AITask — an overlay
/// ABOVE the terminal surface, never text written into the Ghostty
/// buffer. The card never becomes firstResponder outside its input and
/// edit modes, so arrow keys keep reaching the terminal.


final class AITaskCard: NSView {
    var onConfirm: (() -> Void)?
    var onEdit: ((AIProposal) -> Void)?
    var onCancel: (() -> Void)?
    var onContinue: (() -> Void)?
    var onClose: (() -> Void)?
    /// Input mode (⌘⇧A): Enter submits the typed request.
    var onSubmit: ((String) -> Void)?

    private let stack = NSStackView()
    /// The ask that started the running task — shown as the card's
    /// title line (the user's own words, not a phase label).
    private var taskQuestion: String?
    private var inputMode = false
    private var editMode = false
    private var editingProposal: AIProposal?
    /// Last rendered task/target — the theme-change re-render source.
    private var lastTask: AITask?
    private var lastTarget: ExecutionTarget?
    private var inputField: ChromeInput?

    /// The Settings-window translucency, exactly: ONE background@opacity
    /// fill and theme text on top — no blur (the Settings window itself
    /// runs unblurred: no background-blur in the config). An in-window
    /// NSVisualEffectView was tried here and STARVED text rendering
    /// (box paints from layer properties; NSTextFields need display
    /// passes the effect view's per-frame invalidation ate) — 2026-08-27
    /// "card shows no text" report.
    private func applyBackdrop() {
        layer?.backgroundColor = chromeSurface(Chrome.theme.background).cgColor
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = ControlMetrics.radius + 2
        layer?.borderWidth = 1
        layer?.borderColor = Chrome.theme.hairline.cgColor
        applyBackdrop()

        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged),
            name: Chrome.themeDidChange, object: nil)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Fixed title bar: the question and the always-on close stay
        // PINNED; only the body scrolls. The old header lived inside
        // the document and scrolled away with the rounds.
        titleField.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleField.textColor = Chrome.theme.foreground
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.cell?.truncatesLastVisibleLine = true
        titleField.cell?.wraps = false
        titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleField.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        // The header NEVER yields vertically: when the pane cap binds,
        // the solver must shrink the BODY scroller (its hug is 999),
        // not crush the title (labels default to 750 — the "titlebar
        // collapses at max height" report).
        titleField.setContentCompressionResistancePriority(.required, for: .vertical)
        titleField.setContentHuggingPriority(.required, for: .vertical)
        titleField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleField)

        metaField.font = .systemFont(ofSize: 11)
        metaField.textColor = Chrome.theme.secondaryText
        metaField.lineBreakMode = .byTruncatingTail
        metaField.maximumNumberOfLines = 1
        metaField.cell?.truncatesLastVisibleLine = true
        metaField.cell?.wraps = false
        metaField.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        metaField.setContentCompressionResistancePriority(.required, for: .vertical)
        metaField.setContentHuggingPriority(.required, for: .vertical)
        metaField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(metaField)

        // Always-on close (title-bar right): closing cancels a running
        // agent (AppDelegate wires onClose to cancel).
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.symbol = "xmark"
        closeButton.tint = Chrome.theme.secondaryText
        closeButton.usesThemeTint = false
        closeButton.pointSize = 12
        closeButton.onClick = { [weak self] in self?.onClose?() }
        addSubview(closeButton)

        let headerRule = HairlineView()
        headerRule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerRule)

        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -6),
            metaField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            metaField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 1),
            metaField.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -6),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 22),
            closeButton.heightAnchor.constraint(equalToConstant: 22),
            headerRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerRule.topAnchor.constraint(equalTo: metaField.bottomAnchor, constant: 6),
            headerRule.heightAnchor.constraint(equalToConstant: 1),
        ])

        // The stack scrolls instead of crushing: the card hugs its
        // content up to the pane cap (required constraint from the
        // host), beyond which the BODY scrolls under the fixed header.
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = stack
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: headerRule.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])
        // The card = fixed header + body; the body hugs its content
        // (yielding to the host's pane cap, beyond which it scrolls).
        let hug = scrollView.heightAnchor.constraint(equalTo: stack.heightAnchor)
        hug.priority = .init(999)   // yield to the pane cap
        hug.isActive = true
        // The stack's height is pinned EXPLICITLY to its fitting
        // height and re-measured per layout pass — otherwise the stack
        // collapses and crushes the markdown box to a line.
        bodyHeight = stack.heightAnchor.constraint(equalToConstant: 0)
        bodyHeight?.priority = .init(999)   // yield to the pane cap
        bodyHeight?.isActive = true
    }

    private var bodyHeight: NSLayoutConstraint?
    /// The card's body scroller — the clip view owns scrolling (the
    /// document view's bounds origin is the clip's to manage).
    private let scrollView = NSScrollView()
    /// Fixed title-bar fields (question + meta) — pinned above the
    /// scrolling body, set by Group.header on every render.
    private let titleField = NSTextField(labelWithString: "")
    private let metaField = NSTextField(labelWithString: "")
    private let closeButton = IconButton()

    override func layout() {
        super.layout()
        bodyHeight?.isActive = false
        let fitting = ceil(stack.fittingSize.height)
        bodyHeight?.constant = fitting
        bodyHeight?.isActive = true
        if pendingScroll {
            pendingScroll = false
            DispatchQueue.main.async { [stack] in
                // Force the re-measured height to LAND first — reading
                // bounds.height before the constraint pass completes
                // scrolls to the PRE-growth height, which during
                // streaming looked like the card jumping to its top.
                stack.layoutSubtreeIfNeeded()
                stack.scroll(NSPoint(x: 0, y: stack.bounds.height))
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // MARK: modes

    /// ⌘⇧A: an empty card with a request field. Submitting follows the
    /// exact @ai path (PaneHost routes onSubmit to onAITask).
    var isInputMode: Bool { inputMode }

    func enterInputMode(target: ExecutionTarget?) {
        inputMode = true
        editMode = false
        rebuild { group in
            group.header(question: nil, target: target, phase: "Ask AI")
            let field = ChromeInput(placeholder: "Ask the model to do what, where?")
            field.onReturn = { [weak self] in self?.submitInput() }
            field.onEscape = { [weak self] in self?.onClose?() }
            self.inputField = field
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
    /// Container chrome re-baked + content re-rendered from the stored
    /// task on theme flips (content colors are build-time).
    @objc private func themeChanged() {
        applyBackdrop()
        layer?.borderColor = Chrome.theme.hairline.cgColor
        titleField.textColor = Chrome.theme.foreground
        metaField.textColor = Chrome.theme.secondaryText
        if let task = lastTask, let target = lastTarget {
            render(task: task, target: target)
        }
    }

    func render(task: AITask, target: ExecutionTarget) {
        guard !inputMode else { return }   // typed request wins until submitted
        lastTask = task; lastTarget = target
        taskQuestion = task.context.request
        if editMode { renderEdit(task: task, target: target); return }
        switch task.phase {
        case .idle, .thinking:
            rebuild { group in
                group.header(question: taskQuestion, target: target,
                             phase: (task.streamingText?.isEmpty ?? true) ? "thinking…" : "answering…")
                group.rounds(task.rounds)
                if let r = task.streamingReasoning?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !r.isEmpty {
                    group.thinkingBlock(r)
                }
                if let t = task.streamingText?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !t.isEmpty {
                    _ = group.markdown(t)
                }
            }
        case .awaitingConfirmation:
            if let proposal = task.pendingProposal {
                rebuild { group in
                    group.header(question: taskQuestion, target: target,
                                 phase: "confirmation required")
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
                group.header(question: taskQuestion, target: target,
                             phase: "round budget exhausted")
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
            rebuild { group in
                group.header(question: taskQuestion, target: target, phase: "executing…")
                group.rounds(task.rounds)
            }
        case .completed(let summary):
            rebuild { group in
                group.header(question: taskQuestion, target: target, phase: "done")
                group.rounds(task.rounds)
                _ = group.markdown(summary)
            }
        case .failed(let message):
            rebuild { group in
                group.header(question: taskQuestion, target: target, phase: "failed")
                _ = group.markdown(message)
                group.buttons {
                    $0.add("Close", .ghost) { [weak self] in self?.onClose?() }
                }
            }
        case .cancelled:
            rebuild { group in
                group.header(question: taskQuestion, target: target, phase: "cancelled")
            }
        }
    }

    // MARK: edit mode

    private func renderEdit(task: AITask, target: ExecutionTarget) {
        guard let proposal = editingProposal ?? task.pendingProposal else { return }
        editingProposal = proposal
        rebuild { group in
            group.header(question: taskQuestion, target: target, phase: "edit proposal")
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

    var isTextViewSelectableForTest: Bool { selectableFieldForTest != nil }
    var selectableFieldForTest: NSView? {
        stack.views.compactMap { $0 as? NSTextField }.first { $0.isSelectable }
    }
    func renderForTest(markdown: String) {
        rebuild { group in _ = group.markdown(markdown) }
    }

    private func rebuild(_ build: (Group) -> Void) {
        for view in stack.views { stack.removeView(view) }
        inputField = nil
        build(Group(card: self))
        // resize snapped the view back to the top — scroll AFTER layout.
        pendingScroll = true
        // The scroll view isolates layout: stack changes don't mark the
        // card dirty, so re-measure explicitly on the next pass.
        needsLayout = true
    }

    /// Set by rebuild, consumed by layout(): scroll to the bottom once
    /// the re-measured height has actually landed.
    private var pendingScroll = false

    /// Section helpers scoped to one rebuild. Views keep default tag 0;
    /// edit-mode editors carry their parse tag.
    struct Group {
        let card: AITaskCard
        private var stack: NSStackView { card.stack }

        func header(question: String?, target: ExecutionTarget?, phase: String) {
            let name = target?.displayName ?? "Local"
            let cwd = target?.cwd ?? "~"
            // The FIXED title bar: the user's original ask (one bold
            // truncated line) and the meta line (AI · phase · target)
            // update IN PLACE — they never scroll away with the body.
            card.titleField.stringValue = question ?? ""
            card.metaField.stringValue = "AI · \(phase) · \(name) · \(cwd)"
        }

        func rounds(_ rounds: [AIRound]) {
            guard !rounds.isEmpty else { return }
            for round in rounds.suffix(8) {
                if let think = round.reasoning?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !think.isEmpty {
                    thinkingBlock(think)
                }
                // pi/omp shape: one line per round — tool name + the
                // result's first line, tail-truncated (detail is noise).
                let name = round.toolName ?? "tool"
                let first = round.toolResult
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .first.map { "  \($0)" } ?? ""
                let line = mono("› \(name)\(first)")
                line.lineBreakMode = .byTruncatingTail
                line.maximumNumberOfLines = 1
                line.cell?.truncatesLastVisibleLine = true
            }
            if rounds.count > 8 {
                add(views: [label("+\(rounds.count - 8) more rounds",
                                  font: .systemFont(ofSize: 11),
                                  color: Chrome.theme.secondaryText)])
            }
        }


        /// The model's own reasoning for one round: muted mono preview,
        /// capped at 2 lines — it's context for the line under it.
        func thinkingBlock(_ text: String) {
            let body = mono(text)
            body.textColor = Chrome.theme.secondaryText
            body.lineBreakMode = .byTruncatingTail
            body.maximumNumberOfLines = 2
            body.cell?.truncatesLastVisibleLine = true
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
            // lineBreakMode alone does NOT wrap an NSTextField label —
            // cell.wraps is the switch (without it the label stays a
            // single line and clips under the width cap).
            field.lineBreakMode = .byWordWrapping
            field.cell?.wraps = true
            field.cell?.truncatesLastVisibleLine = true
            field.maximumNumberOfLines = 0
            add(views: [field])
            field.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor,
                                         constant: -24).isActive = true
            return field
        }

        /// Markdown flows INLINE with the rest of the card: one
        /// attributed selectable label in the stack. The old box was a
        /// nested text editor in its OWN scroll view inside the card's
        /// scroller — two scroll systems fought for the pin during
        /// streaming (the "md scrolling is chaotic" report).
        @discardableResult
        func markdown(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: "")
            field.textColor = Chrome.theme.foreground
            field.attributedStringValue = MarkdownRenderer.render(
                text, bodySize: 12.5,
                highlight: { code, lang in
                    HighlightEngine.highlight(
                        code, language: lang,
                        font: .monospacedSystemFont(ofSize: 11.5, weight: .regular),
                        color: Chrome.theme.foreground)
                })
            field.isSelectable = true
            field.lineBreakMode = .byWordWrapping
            field.cell?.wraps = true
            field.cell?.truncatesLastVisibleLine = false
            field.maximumNumberOfLines = 0
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            add(views: [field])
            field.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor,
                                         constant: -24).isActive = true
            return field
        }

        /// Selectable mono text (tool output, transcripts) — flat like
        /// everything else; the stack scrolls, no internal scroller.
        @discardableResult
        func monoSelectable(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            field.textColor = Chrome.theme.foreground
            field.isSelectable = true
            field.lineBreakMode = .byWordWrapping
            field.cell?.wraps = true
            field.cell?.truncatesLastVisibleLine = false
            field.maximumNumberOfLines = 0
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            add(views: [field])
            field.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor,
                                         constant: -24).isActive = true
            return field
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

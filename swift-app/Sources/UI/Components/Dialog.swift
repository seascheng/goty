// goty — see CLAUDE.md for the working principles.
import AppKit

// MARK: - Dialogs (tty7: in-window prompts, our own chrome — no NSAlert)

enum Dialog {
    /// Destructive confirmation — red primary button, Cancel second.
    @discardableResult
    static func confirm(title: String, detail: String, action: String) -> Bool {
        present(title: title, detail: detail, primary: action, cancel: "Cancel",
                destructive: true, promptPlaceholder: nil) != nil
    }

    /// Text input — nil on cancel; empty/invalid names rejected here.
    /// `detail` is the muted line under the title (e.g. where a new
    /// worktree will land) — nil keeps the bare prompt.
    static func prompt(title: String, detail: String? = nil, placeholder: String) -> String? {
        let text = present(title: title, detail: detail, primary: "OK", cancel: "Cancel",
                           destructive: false, promptPlaceholder: placeholder)
        guard let text else { return nil }
        let name = text.trimmingCharacters(in: .whitespaces)
        return name.isEmpty || name.contains("/") ? nil : name
    }

    /// Free-form single-line text (tab titles may contain anything,
    /// including "/"); nil ONLY on cancel — an empty answer is a real
    /// answer (the caller's clear rule). `initial` pre-fills and
    /// selects the field (the rename interaction).
    static func promptText(title: String, placeholder: String,
                           initial: String? = nil) -> String? {
        present(title: title, detail: nil, primary: "OK", cancel: "Cancel",
                destructive: false, promptPlaceholder: placeholder,
                promptInitial: initial)
    }

    static func error(title: String, detail: String) {
        _ = present(title: title, detail: detail, primary: "OK", cancel: nil,
                    destructive: false, promptPlaceholder: nil)
    }

    /// Test seam: when set, answers without presenting (headless
    /// harnesses have no window for Return/Esc routing).
    static var presenterOverride: ((String, String?) -> String?)?
    /// One card in its OWN modal panel, centered over the parent
    /// window's content — a REAL modal session (`runModal`, the
    /// machinery NSAlert itself uses). The synchronous signature every
    /// call site relies on is preserved.
    ///
    /// 2026-08-23 root cause (twice bitten: host-picker prompt, then
    /// the worktree prompt): this used to hand-roll the modal — paint
    /// the card into the key window and poll `RunLoop.run(mode:.default)`
    /// in 50ms slices. Opened from an NSMenu action, the menu's
    /// tracking session still owned the event stream; the poll loop
    /// starved, the card painted but never answered clicks, the app
    /// froze. A modal session hands the stream over correctly.
    @discardableResult
    private static func present(title: String, detail: String?, primary: String,
                                cancel: String?, destructive: Bool,
                                promptPlaceholder: String?,
                                promptInitial: String? = nil) -> String? {
        if let presenterOverride {
            let isPrompt = promptPlaceholder != nil
            return presenterOverride(isPrompt ? "prompt" : title, isPrompt ? "entered-text" : detail)
        }

        var answer: String?
        let card = PromptCard(title: title, detail: detail, primary: primary,
                              cancel: cancel, destructive: destructive,
                              placeholder: promptPlaceholder)
        card.onPrimary = { answer = card.input?.stringValue ?? ""; NSApp.stopModal() }
        card.onCancel = { answer = nil; NSApp.stopModal() }
        if let initial = promptInitial, !initial.isEmpty, let input = card.input {
            input.stringValue = initial
            Dialog.presentCard(card, width: PromptCard.cardWidth, focus: {
                input.selectAllText()
            })
            return answer
        }
        Dialog.presentCard(card, width: PromptCard.cardWidth,
                           focus: { card.focusPrimary() })
        return answer
    }
    /// A designed card in the SAME modal machinery (backdrop, real
    /// runModal session) — the ONE modal surface of the product: every
    /// dialog (Dialog.prompt's PromptCard, WorktreeCard, any future
    /// card) presents through here. The passed card carries its own
    /// inputs and buttons and routes Esc/Return through
    /// `DialogCard.onPrimary/onCancel`; those MUST end the session
    /// (`NSApp.stopModal`).
    ///
    /// Focus timing (the 2026-08-24 caret bug): a dialog opened from a
    /// menu action runs INSIDE the menu's tracking session —
    /// makeKeyAndOrderFront is deferred until the menu unwinds, so
    /// every focus call before that lands in a not-yet-key panel and
    /// the NSTextView's insertion-point blink never starts (typing
    /// works, no caret). The panel's didBecomeKey is the authoritative
    /// moment: focus fires there, plus immediately and one main-queue
    /// tick later for paths without a key transition.
    static func presentCard(_ card: DialogCard, width: CGFloat,
                            focus: (() -> Void)? = nil) {
        guard let parent = NSApp.windows.first(where: { $0.isKeyWindow })
                ?? NSApp.windows.first else { return }
        let panel = Dialog.modalPanel(for: parent)

        let backdrop = NSView()
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor

        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.backgroundColor = chromeSurface(Chrome.theme.topBarBackground).cgColor
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Chrome.theme.hairline.cgColor

        let container = NSView()
        container.addSubview(backdrop)
        backdrop.addSubview(card)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: container.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            card.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: width),
        ])
        panel.contentView = container
        container.autoresizingMask = [.width, .height]
        container.layoutSubtreeIfNeeded()

        final class KeyRequestBox {
            var rounds = 0
            var stopped = false
        }
        final class KeyObserverBox {
            var observer: NSObjectProtocol?
            var keyRequests: KeyRequestBox?
        }
        let keyBox = KeyRequestBox()
        let box = KeyObserverBox()
        box.keyRequests = keyBox
        box.observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main
        ) { _ in
            Self.trace("panel became key")
            // Hop out of the key-transition notification before
            // touching first responders — but via the RUNLOOP, not
            // the main queue: runModal is routinely entered from a
            // main-queue block (menu actions defer one tick), and
            // libdispatch never drains the main queue reentrantly —
            // a DispatchQueue.main hop starves for the whole modal
            // session. RunLoop.perform fires on the next pass in the
            // CURRENT mode.
            RunLoop.main.perform {
                focus?()
                Self.trace("after focus: FR=\(String(describing: type(of: panel.firstResponder))) isTextview=\(panel.firstResponder is NSTextView)")
            }
            keyBox.stopped = true
            if let observer = box.observer {
                NotificationCenter.default.removeObserver(observer)
                box.observer = nil
            }
        }
        // Make-key rounds (2026-08-24, the menu-path caret bug): a
        // dialog opened from a menu action runs inside the menu's
        // tracking session — makeKeyAndOrderFront is DEFERRED, the
        // unwind then hands key back to the PARENT, and the modal
        // panel can spend the whole session keyless (verified by
        // probe: keyWindow stayed the parent). A caret blinks only in
        // the key window, so it never started.
        panel.makeKeyAndOrderFront(nil)
        Self.trace("present: initial makeKey, isKey=\(panel.isKeyWindow)")
        focus?()
        // Focus/make-key retries ride a RUNLOOP TIMER in both the
        // default and modal-panel modes — never the main dispatch
        // queue: runModal is routinely entered from inside a main-
        // queue block (menu actions defer one tick), and libdispatch
        // will not drain the main queue reentrantly, so every
        // async/asyncAfter scheduled here starves until the modal
        // ends (the 2026-08-24 caret hunt: retries "ran" but never
        // fired).
        let modalMode = RunLoop.Mode(rawValue: "NSModalPanelRunLoopMode")
        let retry = Timer(timeInterval: 0.1, repeats: true) { t in
            if keyBox.stopped || panel.isKeyWindow || keyBox.rounds >= 20 {
                Self.trace("retry end: stopped=\(keyBox.stopped) isKey=\(panel.isKeyWindow) rounds=\(keyBox.rounds)")
                t.invalidate()
                return
            }
            keyBox.rounds += 1
            panel.makeKeyAndOrderFront(nil)
            focus?()
            Self.trace("timer round \(keyBox.rounds): isKey=\(panel.isKeyWindow)")
        }
        RunLoop.main.add(retry, forMode: .default)
        RunLoop.main.add(retry, forMode: modalMode)
        // One focus pass INSIDE the modal loop: the initial focus
        // above may have run while the opening menu's tracking session
        // still owned the runloop (eventTracking mode) — the text
        // view's blink timer gets scheduled in THAT mode and never
        // ticks once the modal loop takes over. The dance in
        // ChromeInput.focus() re-runs becomeFirstResponder here, in
        // the modal mode, so the timer lands where it actually ticks.
        let firstModalTick = Timer(timeInterval: 0.05, repeats: false) { _ in
            focus?()
            Self.trace("modal-tick focus: FR-is-textview=\(panel.firstResponder is NSTextView)")
        }
        RunLoop.main.add(firstModalTick, forMode: modalMode)
        RunLoop.main.add(firstModalTick, forMode: .default)
        NSApp.runModal(for: panel)
        keyBox.stopped = true
        retry.invalidate()
        if let observer = box.observer {
            NotificationCenter.default.removeObserver(observer)
            box.observer = nil
        }
        panel.orderOut(nil)
    }

    /// The modal host: borderless panels are not key by default, and a
    /// prompt's input needs the keyboard.
    private static func modalPanel(for parent: NSWindow) -> NSPanel {
        final class ModalPanel: NSPanel {
            override var canBecomeKey: Bool { true }
        }
        let panel = ModalPanel(contentRect: parent.contentRect(forFrameRect: parent.frame),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .modalPanel
        return panel
    }
    /// Env-gated dialog timing trace (GOTY_DIALOG_DEBUG=1): the
    /// make-key choreography is invisible without it.
    private static func trace(_ line: String) {
        guard ProcessInfo.processInfo.environment["GOTY_DIALOG_DEBUG"] == "1" else { return }
        let url = URL(fileURLWithPath: "/tmp/goty-dialog-trace.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = FileHandle(forWritingAtPath: url.path)
        handle?.seekToEndOfFile()
        handle?.write(Data("\(Date()) \(line)\n".utf8))
    }
}

/// One dialog card: routes Esc/Return (Dialog.prompt's buttons share
/// it); designed cards subclass it (WorktreeCard).
class DialogCard: NSView {
    var onPrimary: (() -> Void)?
    var onCancel: (() -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 { onCancel?(); return true }   // Esc
        if event.keyCode == 36 { onPrimary?(); return true }  // Return
        return super.performKeyEquivalent(with: event)
    }
}

/// The standard card Dialog.prompt/confirm/promptText/error render —
/// the same DialogCard chassis WorktreeCard builds on, the same
/// presentCard machinery, the same metrics. ONE prompt look for the
/// whole product; designed cards (WorktreeCard) are its wide-card
/// siblings, never a second design.
final class PromptCard: DialogCard {
    static let cardWidth: CGFloat = 340

    /// The input, when this is a prompt (nil = confirm/error card).
    private(set) var input: ChromeInput?

    init(title: String, detail: String?, primary: String, cancel: String?,
         destructive: Bool, placeholder: String?) {
        super.init(frame: .zero)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = Chrome.theme.foreground
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        var previous: NSView = titleLabel
        if let detail, !detail.isEmpty {
            let detailLabel = NSTextField(labelWithString: detail)
            detailLabel.font = .systemFont(ofSize: 12)
            detailLabel.textColor = Chrome.theme.secondaryText
            detailLabel.alignment = .left
            detailLabel.lineBreakMode = .byWordWrapping
            detailLabel.maximumNumberOfLines = 6
            detailLabel.cell?.truncatesLastVisibleLine = true
            detailLabel.cell?.wraps = true
            detailLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(detailLabel)
            NSLayoutConstraint.activate([
                detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
                detailLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
                detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            ])
            previous = detailLabel
        }

        if let placeholder {
            let field = ChromeInput(placeholder: placeholder)
            input = field
            addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
                field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
                field.topAnchor.constraint(equalTo: previous.bottomAnchor, constant: 12),
                field.heightAnchor.constraint(equalToConstant: ControlMetrics.inputHeight),
            ])
            previous = field
        }

        // Buttons END the modal session via onPrimary/onCancel — the
        // caller (Dialog.present) owns the answer capture and
        // stopModal; Return/Esc ride DialogCard.performKeyEquivalent.
        let primaryButton = ChromeButton.make(
            primary, style: destructive ? .danger : .primary) { [weak self] in
            self?.onPrimary?()
        }
        primaryButton.keyEquivalent = "\r"
        addSubview(primaryButton)
        var buttons: [NSView] = [primaryButton]
        if let cancel {
            let cancelButton = ChromeButton.make(cancel, style: .ghost) { [weak self] in
                self?.onCancel?()
            }
            cancelButton.keyEquivalent = "\u{1b}"
            addSubview(cancelButton)
            buttons.insert(cancelButton, at: 0)
        }

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            previous.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            previous.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
        ])
        for (i, b) in buttons.enumerated() {
            b.topAnchor.constraint(
                equalTo: previous.bottomAnchor, constant: 16).isActive = true
            b.bottomAnchor.constraint(
                equalTo: bottomAnchor, constant: -16).isActive = true
            if i == 0 {
                b.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor,
                                           constant: 20).isActive = true
            }
            if i > 0 {
                b.leadingAnchor.constraint(equalTo: buttons[i - 1].trailingAnchor,
                                           constant: 8).isActive = true
            }
            if i == buttons.count - 1 {
                b.trailingAnchor.constraint(equalTo: trailingAnchor,
                                            constant: -20).isActive = true
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    /// The prompt input, or the card itself for confirm/error cards.
    func focusPrimary() {
        if let input {
            input.focus()
        } else {
            window?.makeFirstResponder(self)
        }
    }
}

/// Icon button: SF Symbol glyph in an NSImageView — the system
/// rasterizes symbols natively at the live backing density, exactly as
/// every native Mac app renders them. The single lifecycle rule that
/// matters: re-apply the glyph whenever the window or its backing
/// store changes (a one-shot raster is how the mixed-DPI scale-flip
/// bug happened). Transparent at rest, contrast-lifted fill on hover
/// (tty7 chrome tile).

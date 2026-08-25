// goty — see CLAUDE.md for the working principles.
import AppKit

// MARK: - New Worktree dialog (creation flow v2)

/// The New Worktree card: repo context header, live target preview,
/// inline validation, gated Create — the designed replacement for the
/// bare prompt card (2026-08-24). All decisions live in Core
/// (`WorktreePlan.target` / `validateName`); this view only renders
/// them and refreshes per keystroke. Built as a plain view so tests
/// drive `refresh()` directly; `prompt(root:)` mounts it in
/// `Dialog.presentCard`'s modal session.
final class WorktreeCard: DialogCard {
    /// Test seam, the Dialog.presenterOverride pattern: headless runs
    /// answer without presenting.
    static var presenterOverride: ((String) -> String?)?

    private let root: String
    /// Repo display name (last path segment) and the muted root line.
    private let repoName: String
    private let input = ChromeInput(placeholder: "worktree name",
                                    icon: "arrow.triangle.branch")
    private let previewField = NSTextField(labelWithString: "")
    private let branchField = NSTextField(labelWithString: "")
    private let validationField = NSTextField(labelWithString: "")
    private let createButton = ChromeButton.make("Create Worktree", style: .primary)
    private let cancelButton = ChromeButton.make("Cancel", style: .ghost)
    /// Fired by Return/Create with a VALIDATED name. Cancel/Esc ride
    /// the inherited DialogCard.onCancel.
    var onCreate: ((String) -> Void)?

    /// Card width — room for the full target path preview, the step up
    /// from the 340pt prompt card.
    static let cardWidth: CGFloat = 480

    init(root: String) {
        self.root = root
        self.repoName = (root as NSString).lastPathComponent
        super.init(frame: .zero)

        // No in-card title: the WINDOW's header strip carries it (the
        // SSH-manager pattern — one title, in the traffic-light band).
        // The repo line is the card's top element.

        let repoLabel = NSTextField(labelWithString: "")
        repoLabel.attributedStringValue = Self.repoLine(name: repoName, root: root)
        repoLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(repoLabel)

        let divider = HairlineView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)

        let nameLabel = NSTextField(labelWithString: "")
        nameLabel.attributedStringValue = NSAttributedString(
            string: "NAME", attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: Chrome.theme.secondaryText])
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        input.translatesAutoresizingMaskIntoConstraints = false
        addSubview(input)

        previewField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        previewField.textColor = Chrome.theme.secondaryText
        previewField.lineBreakMode = .byTruncatingMiddle
        previewField.cell?.truncatesLastVisibleLine = true
        previewField.cell?.wraps = false
        previewField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        previewField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previewField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(previewField)

        branchField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        branchField.textColor = Chrome.theme.secondaryText
        branchField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(branchField)

        validationField.font = .systemFont(ofSize: 11, weight: .regular)
        validationField.textColor = Chrome.theme.dangerText
        validationField.lineBreakMode = .byTruncatingTail
        validationField.isHidden = true
        validationField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(validationField)

        input.onDidChange = { [weak self] in self?.refresh() }
        cancelButton.onClick = { [weak self] in self?.cancel() }
        createButton.onClick = { [weak self] in self?.commit() }
        addSubview(cancelButton)
        addSubview(createButton)

        // Return commits when valid; Escape cancels — the card's own
        // key routing (Dialog.prompt's buttons behave the same).
        onPrimary = { [weak self] in self?.commit() }
        onCancel = { [weak self] in self?.cancel() }
        input.onReturn = { [weak self] in self?.commit() }
        input.onEscape = { [weak self] in self?.cancel() }

        NSLayoutConstraint.activate([
            repoLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            repoLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            repoLabel.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            divider.topAnchor.constraint(equalTo: repoLabel.bottomAnchor, constant: 14),
            divider.heightAnchor.constraint(equalToConstant: 1),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            nameLabel.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 14),
            input.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            input.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            input.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 8),
            input.heightAnchor.constraint(equalToConstant: ControlMetrics.inputHeight),
            previewField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            previewField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            previewField.topAnchor.constraint(equalTo: input.bottomAnchor, constant: 10),
            branchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            branchField.topAnchor.constraint(equalTo: previewField.bottomAnchor, constant: 4),
            validationField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            validationField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            validationField.topAnchor.constraint(equalTo: branchField.bottomAnchor, constant: 8),
            validationField.bottomAnchor.constraint(lessThanOrEqualTo: createButton.topAnchor,
                                                    constant: -12),
            cancelButton.topAnchor.constraint(equalTo: branchField.bottomAnchor, constant: 20),
            cancelButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            createButton.topAnchor.constraint(equalTo: branchField.bottomAnchor, constant: 20),
            createButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            createButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            cancelButton.trailingAnchor.constraint(equalTo: createButton.leadingAnchor,
                                                   constant: -10),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    /// Everything derived from the current name — one path for user
    /// keystrokes and tests.
    func refresh() {
        let name = input.stringValue.trimmingCharacters(in: .whitespaces)
        if name.isEmpty {
            previewField.stringValue = "\(root)-"
            branchField.stringValue = ""
        } else {
            previewField.stringValue = WorktreePlan.target(root: root, name: name)
            branchField.stringValue = "branch \(name), from current HEAD"
        }
        // One gate: Create is armed only by a complete, valid name;
        // the reason line shows exactly when the name is malformed.
        if name.isEmpty {
            validationField.isHidden = true
            createButton.isEnabled = false
        } else if let why = WorktreePlan.validateName(name) {
            validationField.stringValue = why
            validationField.isHidden = false
            createButton.isEnabled = false
        } else {
            validationField.isHidden = true
            createButton.isEnabled = true
        }
    }

    /// Test/commit seam: the Create/Return path, validation-gated.
    func commit() {
        let name = input.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, WorktreePlan.validateName(name) == nil else { return }
        onCreate?(name)
    }

    private func cancel() {
        onCancel?()
    }

    /// Tests type here (stringValue does not fire textDidChange).
    func typeNameForTest(_ name: String) {
        input.stringValue = name
        refresh()
    }

    /// Window-level focus entry (the controller calls this on show
    /// and on didBecomeKey).
    func focusInput() {
        input.focus()
    }

    // Test seams: the three derived surfaces refresh() writes.
    var previewTextForTest: String { previewField.stringValue }
    var validationTextForTest: String? {
        validationField.isHidden ? nil : validationField.stringValue
    }
    var createEnabledForTest: Bool { createButton.isEnabled }
    /// "repo  /full/root/path" — name in the theme foreground, the
    /// root path mono and muted (the card's context line).
    private static func repoLine(name: String, root: String) -> NSAttributedString {
        let line = NSMutableAttributedString(
            string: name,
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                         .foregroundColor: Chrome.theme.foreground])
        line.append(NSAttributedString(
            string: "  " + root,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                         .foregroundColor: Chrome.theme.secondaryText]))
        return line
    }
}

// MARK: - Presentation (standalone window, the SSH-manager recipe)

/// Presents the New Worktree card in its OWN non-modal titled window —
/// exactly the SSHConfigWindowController recipe. This replaces the
/// 2026-08-23 modal card: a dialog opened from a menu action runs
/// inside the menu's tracking session, and the modal machinery built
/// on that path stacked three AppKit traps (deferred make-key, blink
/// timer scheduled in eventTracking mode, main-queue starvation inside
/// runModal) that left the input without a caret. A normal window has
/// none of them: key arrives naturally, the runloop never blocks, the
/// caret behaves like every other window's input.
enum WorktreeWindow {
    /// Test seam, the Dialog.presenterOverride pattern: headless runs
    /// answer without presenting.
    static var presenterOverride: ((String) -> String?)?

    private static var backing: WorktreeWindowController?

    /// Show (or re-show) the New Worktree window for `root`; `onCreate`
    /// fires with the validated name when the user commits. Cancel/Esc/
    /// window-close simply closes — no callback.
    static func present(root: String, over parent: NSWindow?,
                        onCreate: @escaping (String) -> Void) {
        if let presenterOverride {
            presenterOverride(root).map(onCreate)
            return
        }
        // One at a time: reopening swaps the repo instead of stacking
        // windows (the '+' flyout opens from whatever space is focused).
        backing?.close()
        let controller = WorktreeWindowController(
            root: root, onCreate: onCreate)
        backing = controller
        controller.show(over: parent)
    }

    static func closeForTest() {
        backing?.close()
        backing = nil
    }
}

final class WorktreeWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let card: WorktreeCard
    private let onCreate: (String) -> Void
    private var keyObserver: NSObjectProtocol?

    init(root: String, onCreate: @escaping (String) -> Void) {
        self.onCreate = onCreate
        let card = WorktreeCard(root: root)
        self.card = card

        // The SSH-manager chrome: a 40pt header strip in
        // topBarBackground carries the traffic lights AND the one
        // title (x=84 clears the capsules); the card starts below it.
        // No blank margin band (the 2026-08-24 report — a light band
        // with nothing in it reads as a bug).
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = Chrome.theme.background.cgColor
        let strip = NSView()
        strip.wantsLayer = true
        strip.layer?.backgroundColor = Chrome.theme.topBarBackground.cgColor
        strip.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(strip)
        let stripTitle = NSTextField(labelWithString: "NEW WORKTREE")
        stripTitle.attributedStringValue = NSAttributedString(
            string: "NEW WORKTREE",
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                         .foregroundColor: Chrome.theme.foreground,
                         .kern: 0.8])
        stripTitle.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(stripTitle)
        card.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(card)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: WorktreeCard.cardWidth, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "New Worktree"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden   // the strip's title is the one title
        window.appearance = NSAppearance(
            named: Chrome.theme.isDark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false   // retained by WorktreeWindow
        self.window = window
        super.init()
        window.delegate = self

        window.contentView = container
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            strip.topAnchor.constraint(equalTo: container.topAnchor),
            strip.heightAnchor.constraint(equalToConstant: 40),
            stripTitle.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 84),
            stripTitle.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
            card.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            card.topAnchor.constraint(equalTo: strip.bottomAnchor),
            card.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.layoutSubtreeIfNeeded()
        let size = card.fittingSize
        let content = NSSize(width: WorktreeCard.cardWidth,
                             height: size.height + 40)
        window.setContentSize(content)
        window.contentMinSize = content
        window.contentMaxSize = content

        card.onCreate = { [weak self] name in
            self?.close()
            self?.onCreate(name)
        }
        card.onCancel = { [weak self] in self?.close() }
    }

    func show(over parent: NSWindow?) {
        if let parent {
            let pc = parent.frame
            let f = window.frame
            window.setFrameOrigin(NSPoint(
                x: pc.midX - f.width / 2,
                y: pc.midY - f.height / 2))
        }
        window.makeKeyAndOrderFront(nil)
        // Key may still be deferred if we were opened from a menu
        // action; re-focus when it actually lands (plain notification,
        // runloop-attached — no modal loop is involved).
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window,
            queue: .main
        ) { [weak self] _ in
            self?.card.focusInput()
        }
        card.focusInput()
    }

    func close() {
        if let observer = keyObserver {
            NotificationCenter.default.removeObserver(observer)
            keyObserver = nil
        }
        window.delegate = nil
        window.orderOut(nil)
    }

    /// The close button / ⌘W: same as Cancel.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }
}

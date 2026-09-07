// goty — see CLAUDE.md for the working principles.
import AppKit

/// The @ai task card as a GRID CELL (tty7 model). The card used to be a
/// bottom overlay composited over the terminal's prompt area — AI work
/// and shell work could not coexist. Here the same AITaskCard fills a
/// real pane cell: the terminal keeps its own cell above, each side has
/// its own keyboard focus, and the card scrolls inside a FIXED cell
/// height (no content-driven re-layout, so nothing jumps while the
/// terminal resizes).
final class AITaskPaneHost: NSView, PaneHosting, ThemeRefreshable {
    let hostKey: HostKey
    var windowVisible: Bool = true
    /// Submitting from the composer follows the same path as a captured
    /// @ai line (the AppDelegate routes it to the tab's terminal).
    var onSubmit: ((String) -> Void)?
    var coordinatorFeed: (() -> ExecutionTarget?)?
    private let card = AITaskCard()
    init(key: HostKey) {
        self.hostKey = key
        super.init(frame: .zero)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        // Full-bleed MINUS a margin: the agent-gui composer breathes
        // inside its cell. The card FILLS the fixed cell (its internal
        // scroll view owns overflow) — cell height is the grid's, never
        // the content's, so nothing fights the terminal for space.
        card.setFillsContainer(true)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            card.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    // MARK: - task surface (the AppDelegate routes coordinator updates
    // here exactly where PaneHost.showAITask used to go)

    func render(task: AITask) {
        card.render(task: task, target: task.context.target)
    }

    @objc func retheme() {}

    func enterInputMode() {
        card.enterInputMode(target: coordinatorFeed?())
        // The card's own makeFirstResponder runs before the freshly
        // mounted cell is in a window — re-fire after the layout pass.
        DispatchQueue.main.async { [weak card] in card?.focusInput() }
    }

    var taskCard: AITaskCard { card }

    // MARK: - PaneHosting

    func setVisible(_ visible: Bool) { isHidden = !visible }
    func syncCoreVisibility() {}
    func retire() {
        // The pane is gone from the store — release the task wiring.
        onSubmit = nil
        coordinatorFeed = nil
        removeFromSuperview()
    }
    func focusAsPane() {
        // The card's request/follow-up field is the typing surface.
        window?.makeFirstResponder(card.nextValidKeyView)
    }
    func createSurfaceIfNeeded() {}

    // retheme() is the ThemeRefreshable entry (declared above); the
    // card paints from Chrome.theme at content build time.
}

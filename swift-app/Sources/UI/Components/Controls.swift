// goty — see CLAUDE.md for the working principles.
import AppKit

// MARK: - Themed controls (the app's one control layer)

/// Control metrics in ONE place (tty7 rounding.rs discipline): every
/// input, button and card reads these — no call-site literals.
enum ControlMetrics {
    /// Card/input/button corner (tty7 CARD_RADIUS; Dialog cards use 6).
    static let radius: CGFloat = 6
    /// Single-line input height.
    static let inputHeight: CGFloat = 30
    /// Button height.
    static let buttonHeight: CGFloat = 28
    /// Button minimum width — one floor so short labels ("OK", "Save")
    /// never read smaller than their row siblings ("Cancel").
    static let buttonMinWidth: CGFloat = 76
}

/// The themed button — the Dialog card's self-painted recipe promoted
/// to a component. NEVER a plain NSButton look: native controls follow
/// the SYSTEM appearance, but this chrome follows the ghostty theme
/// (Chrome.theme), so buttons paint their own fill/border/title from
/// theme tokens. Colors re-apply on viewDidMoveToWindow (the IconButton
/// rule) so a future ghostty-theme switch repaints on re-present.
final class ChromeButton: ClosureButton {
    enum Style {
        /// Filled with the theme accent (ghostty selection-background).
        case primary
        case ghost
        /// Filled destructive red (Dialog confirm).
        case danger
    }

    private let style: Style
    private var titleText: String = ""

    static func make(_ title: String, style: Style,
                     onClick: (() -> Void)? = nil) -> ChromeButton {
        let b = ChromeButton(title: title, style: style)
        b.onClick = onClick
        return b
    }

    /// Gate + dim: a disabled action button must LOOK disabled (the
    /// worktree dialog's Create is validation-gated). ClosureButton's
    /// mouseDown bypasses NSControl's gating, so clicks are swallowed
    /// here too.
    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            applyTheme()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        super.mouseDown(with: event)
    }


    init(title: String, style: Style) {
        self.style = style
        self.titleText = title
        super.init(frame: .zero)
        // Self-painted chrome: the native bezel must be OFF or macOS
        // draws its own rounded rect UNDER our layer — two borders of
        // different sizes (the 2026-08-24 worktree-window report).
        isBordered = false
        controlSize = .small
        font = .systemFont(ofSize: 12, weight: .medium)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // The component owns its design-system size: every ChromeButton
        // in the product is buttonHeight tall and at least buttonMinWidth
        // wide — call sites position, never resize (2026-08-24 report:
        // per-call-site sizing grew unequal buttons).
        widthAnchor.constraint(
            greaterThanOrEqualToConstant: ControlMetrics.buttonMinWidth).isActive = true
        heightAnchor.constraint(
            equalToConstant: ControlMetrics.buttonHeight).isActive = true
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder: not implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTheme()
    }

    private func applyTheme() {
        layer?.cornerRadius = ControlMetrics.radius
        let alpha: CGFloat = isEnabled ? 1 : 0.4
        switch style {
        case .primary:
            layer?.backgroundColor = Chrome.theme.accent.withAlphaComponent(alpha).cgColor
            layer?.borderWidth = 0
            attributedTitle = attributed(titleText, color: Chrome.theme.accentText.withAlphaComponent(alpha))
        case .ghost:
            layer?.backgroundColor = nil
            layer?.borderWidth = 1
            layer?.borderColor = Chrome.theme.hairline.withAlphaComponent(alpha).cgColor
            attributedTitle = attributed(titleText, color: Chrome.theme.foreground.withAlphaComponent(alpha))
        case .danger:
            layer?.backgroundColor = Chrome.theme.dangerFill.withAlphaComponent(alpha).cgColor
            layer?.borderWidth = 0
            attributedTitle = attributed(titleText, color: NSColor.white.withAlphaComponent(alpha))
        }
    }

    private func attributed(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                         .foregroundColor: color])
    }
}

/// Themed popup: self-painted ghost-style button (value + chevron)
/// that opens an NSMenu — NEVER NSPopUpButton (native controls follow
/// the SYSTEM appearance; this chrome follows Chrome.theme). Menus
/// themselves are native everywhere in this app, so the dropdown list
/// stays consistent; the collapsed control is ours.
final class ChromePopup: NSView {
    var onChange: ((String?) -> Void)?
    /// All options: label + written value (nil = ghostty default).
    private(set) var options: [(label: String, value: String?)] = []
    private var selected = 0

    private let valueLabel = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var hovered = false
    private var ownTracking: NSTrackingArea?

    static func make(width: CGFloat = 210) -> ChromePopup {
        let p = ChromePopup()
        p.translatesAutoresizingMaskIntoConstraints = false
        p.widthAnchor.constraint(equalToConstant: width).isActive = true
        p.heightAnchor.constraint(equalToConstant: ControlMetrics.inputHeight).isActive = true
        return p
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = ControlMetrics.radius
        layer?.borderWidth = 1

        valueLabel.font = .systemFont(ofSize: 12)
        valueLabel.lineBreakMode = .byTruncatingMiddle
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(valueLabel)

        chevron.image = NSImage(systemSymbolName: "chevron.down",
                                accessibilityDescription: nil)
        chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)

        NSLayoutConstraint.activate([
            valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            valueLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -6),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder: not implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Tracking ONCE (the IconButton rule).
        if ownTracking == nil {
            let t = NSTrackingArea(rect: .zero,
                                   options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                   owner: self, userInfo: nil)
            addTrackingArea(t)
            ownTracking = t
        }
        applyTheme()
    }

    private func applyTheme() {
        layer?.borderColor = (hovered ? Chrome.theme.hoverFill : Chrome.theme.hairline).cgColor
        layer?.backgroundColor = hovered ? Chrome.theme.hoverFill.cgColor : nil
        valueLabel.textColor = hovered ? Chrome.theme.foreground : Chrome.theme.foreground.withAlphaComponent(0.9)
        chevron.contentTintColor = Chrome.theme.secondaryText
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; applyTheme() }
    override func mouseExited(with event: NSEvent) { hovered = false; applyTheme() }

    override func mouseDown(with event: NSEvent) {
        let menu = NSMenu()
        for (i, option) in options.enumerated() {
            let item = NSMenuItem(title: option.label, action: #selector(pick(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = i
            item.state = i == selected ? .on : .off
            item.image = swatches?[option.label]
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let i = sender.representedObject as? Int, options.indices.contains(i)
        else { return }
        selected = i
        valueLabel.stringValue = options[i].label
        applyTheme()
        onChange?(options[i].value)
    }

    /// Per-label menu images (theme swatches), by label.
    var swatches: [String: NSImage]?

    /// Loads options and selects the one matching `current` (a raw
    /// value; nil selects the first option, the default row).
    func load(options: [(label: String, value: String?)], current: String?) {
        self.options = options
        selected = options.firstIndex { $0.value == current } ?? 0
        valueLabel.stringValue = options[selected].label
    }

    var selectedLabelForTest: String? { options.indices.contains(selected) ? options[selected].label : nil }
    func pickForTest(_ label: String) {
        if let i = options.firstIndex(where: { $0.label == label }) {
            selected = i
            valueLabel.stringValue = options[i].label
            onChange?(options[i].value)
        }
    }
}

/// Themed toggle: self-painted pill + knob (never NSSwitch — system
/// appearance). One click flips and fires.
final class ChromeToggle: NSView {
    var onChange: ((Bool) -> Void)?
    private(set) var isOn: Bool
    private var hovered = false
    private var ownTracking: NSTrackingArea?

    init(on: Bool = false) {
        self.isOn = on
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        widthAnchor.constraint(equalToConstant: 38).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder: not implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if ownTracking == nil {
            let t = NSTrackingArea(rect: .zero,
                                   options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                   owner: self, userInfo: nil)
            addTrackingArea(t)
            ownTracking = t
        }
        repaint()
    }

    override func draw(_ dirtyRect: NSRect) { repaint() }

    private func repaint() {
        let track = isOn ? Chrome.theme.accent
                         : (hovered ? Chrome.theme.hoverFill : Chrome.theme.topBarBackground)
        track.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        if !isOn {
            Chrome.theme.hairline.setStroke()
            let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: bounds.height / 2, yRadius: bounds.height / 2)
            p.lineWidth = 1
            p.stroke()
        }
        // Knob: 18pt circle, slides between the track's ends.
        let knob: CGFloat = 18
        let x = isOn ? bounds.maxX - knob - 2 : 2
        let knobRect = NSRect(x: x, y: (bounds.height - knob) / 2, width: knob, height: knob)
        (isOn ? Chrome.theme.accentText : Chrome.theme.iconTint).setFill()
        NSBezierPath(ovalIn: knobRect).fill()
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        isOn.toggle()
        needsDisplay = true
        onChange?(isOn)
    }

    func setForTest(_ on: Bool) {
        isOn = on
        needsDisplay = true
        onChange?(isOn)
    }
    var isOnForTest: Bool { isOn }
}

/// Themed slider: self-painted track + knob (never NSSlider — system
/// appearance and uncontrolled intrinsic size). Drags fire `onChange`
/// continuously; the caller owns write debouncing.
final class ChromeSlider: NSView {
    var onChange: ((Double) -> Void)?
    let minValue: Double
    let maxValue: Double
    private let step: Double
    private(set) var value: Double

    init(value: Double, min: Double, max: Double, step: Double) {
        self.value = value
        self.minValue = min
        self.maxValue = max
        self.step = step
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 150).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder: not implemented") }

    private func clamp(_ v: Double) -> Double {
        let stepped = (v / step).rounded() * step
        return min(max(stepped, minValue), maxValue)
    }

    private func update(from event: NSEvent) {
        let fraction = Double(convert(event.locationInWindow, from: nil).x / max(bounds.width, 1))
        let v = clamp(minValue + fraction * (maxValue - minValue))
        guard abs(v - value) > 0.0001 else { return }
        value = v
        needsDisplay = true
        onChange?(v)
    }

    override func mouseDown(with event: NSEvent) { update(from: event) }
    override func mouseDragged(with event: NSEvent) { update(from: event) }

    override func draw(_ dirtyRect: NSRect) {
        let trackY = bounds.midY - 1.5
        let track = NSRect(x: 0, y: trackY, width: bounds.width, height: 3)
        Chrome.theme.topBarBackground.setFill()
        NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
        let fraction = (value - minValue) / max(maxValue - minValue, 0.0001)
        let fill = NSRect(x: 0, y: trackY, width: track.width * fraction, height: 3)
        Chrome.theme.accent.setFill()
        NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()
        let knob: CGFloat = 13
        let kx = track.width * fraction - knob / 2
        let kr = NSRect(x: min(max(kx, 0), bounds.width - knob),
                        y: (bounds.height - knob) / 2, width: knob, height: knob)
        Chrome.theme.iconTint.setFill()
        NSBezierPath(ovalIn: kr).fill()
    }

    func setForTest(_ v: Double) {
        value = clamp(v)
        needsDisplay = true
        onChange?(value)
    }
    var valueForTest: Double { value }
}

/// The themed single-line input. OWNS its NSTextView — the one lesson
/// of the 2026-08-23 white-input/blue-border round: the shared FIELD
/// EDITOR is a system object and macOS 26 repaints its background,
/// focus border and selection with the SYSTEM appearance no matter
/// what we set on it. An owned text view (the CommitMessageView
/// recipe) keeps OUR colors permanently: clear background, theme
/// selection fill, theme insertion point, no focus ring.
/// Explicit acts only: Escape fires onEscape, Return fires onReturn.
final class ChromeInput: NSView, NSTextViewDelegate {
    var onEscape: (() -> Void)?
    var onReturn: (() -> Void)?
    /// Fired on every USER edit (tests and programmatic sets call
    /// their own refresh) — the worktree card's live preview.
    var onDidChange: (() -> Void)?

    var stringValue: String {
        get { textView.string }
        set {
            textView.string = newValue
            updatePlaceholder()
        }
    }

    private let placeholderLabel = NSTextField(labelWithString: "")
    fileprivate let textView = InputTextView()

    init(placeholder: String = "", icon: String? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = ControlMetrics.radius
        layer?.masksToBounds = true

        // TextKit1 by construction (the EditorPanel lesson): a real
        // container sized for one no-wrap line.
        let storage = NSTextStorage()
        let container = NSTextContainer(
            size: NSSize(width: CGFloat.greatestFiniteMagnitude,
                        height: ControlMetrics.inputHeight))
        container.widthTracksTextView = false   // no wrap — clip instead
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)

        textView.delegate = self
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.focusRingType = .none
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: ControlMetrics.inputHeight)
        textView.autoresizingMask = [.width]
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = .systemFont(ofSize: 12.5, weight: .regular)
        // NSTextView starts its first line at the TOP of its bounds;
        // center the single line by insetting half the slack (the
        // CommitMessageView lesson — without this the text hugs the
        // top edge of the input).
        let lineHeight = layout.defaultLineHeight(
            for: .systemFont(ofSize: 12.5, weight: .regular))
        textView.textContainerInset = NSSize(
            width: 0, height: max(0, (ControlMetrics.inputHeight - lineHeight) / 2))
        textView.onKeyEscape = { [weak self] in self?.onEscape?() }
        textView.onKeyReturn = { [weak self] in self?.onReturn?() }
        textView.onFocusChange = { [weak self] _ in self?.updatePlaceholder() }
        textView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textView)

        placeholderLabel.attributedStringValue = NSAttributedString(
            string: placeholder,
            attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .regular),
                         .foregroundColor: Chrome.theme.secondaryText])
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderLabel)

        var textLeading = leadingAnchor
        var textLeadingConstant: CGFloat = 10
        if let icon {
            let iconView = NSImageView()
            iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
            iconView.contentTintColor = Chrome.theme.secondaryText
            iconView.symbolConfiguration = .init(pointSize: 12, weight: .regular)
            iconView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(iconView)
            NSLayoutConstraint.activate([
                iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 16),
                iconView.heightAnchor.constraint(equalToConstant: 16),
            ])
            textLeading = iconView.trailingAnchor
            textLeadingConstant = 6
        }

        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: textLeading, constant: textLeadingConstant),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
            placeholderLabel.leadingAnchor.constraint(equalTo: textLeading, constant: textLeadingConstant),
            placeholderLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder: not implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTheme()
        updatePlaceholder()
    }

    /// Every themed surface reapplies on entering the tree (the
    /// IconButton rule — a future ghostty-theme switch repaints on
    /// re-present).
    private func applyTheme() {
        layer?.backgroundColor = Chrome.theme.hoverFill.cgColor
        textView.textColor = Chrome.theme.foreground
        textView.insertionPointColor = Chrome.theme.foreground
        textView.selectedTextAttributes = [
            .backgroundColor: Chrome.theme.accent,
            .foregroundColor: Chrome.theme.accentText,
        ]
    }

    private func updatePlaceholder() {
        // Content-driven only: the window's key-focus pass hands the
        // field first responder before the user types anything, and
        // focus-hiding left the box permanently empty-looking.
        placeholderLabel.isHidden = !textView.string.isEmpty
    }

    func textDidChange(_ notification: Notification) {
        // Single line, always: pasted newlines become spaces.
        if textView.string.contains(where: { $0 == "\n" || $0 == "\r" }) {
            textView.string = textView.string
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
        }
        updatePlaceholder()
        onDidChange?()
    }

    func focus() {
        // The become-dance must run while the window is KEY: a focus
        // that landed during a key transition (menu unwind — the
        // 2026-08-24 worktree caret bug) leaves the text view first
        // responder with a blink that never started, and a later
        // makeFirstResponder no-ops because the responder is already
        // set. Resign first, then re-become — the insertion point
        // timer starts with it.
        if window?.firstResponder === textView {
            window?.makeFirstResponder(nil)
        }
        window?.makeFirstResponder(textView)
        textView.updateInsertionPointStateAndRestartTimer(true)
    }

    func selectAllText() {
        focus()
        textView.selectAll(nil)
    }


    fileprivate final class InputTextView: NSTextView {
        var onKeyEscape: (() -> Void)?
        var onKeyReturn: (() -> Void)?
        var onFocusChange: ((Bool) -> Void)?

        override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder()
            if ok { onFocusChange?(true) }
            return ok
        }

        override func resignFirstResponder() -> Bool {
            let ok = super.resignFirstResponder()
            if ok { onFocusChange?(false) }
            return ok
        }

        override func cancelOperation(_ sender: Any?) {
            onKeyEscape?()
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.keyCode == 36 {   // Return commits (explicit act)
                onKeyReturn?()
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }
}

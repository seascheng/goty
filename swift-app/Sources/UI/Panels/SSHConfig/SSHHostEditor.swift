// goty — see CLAUDE.md for the working principles.
import AppKit

/// The manager's right pane: the selected host's form, built entirely
/// from the themed control layer (ChromeInput / ChromeButton — the
/// ghostty-theme-following controls, never native styling). Labels use
/// the sectionHeader recipe. Return commits, Escape cancels
/// (explicit-acts rule). With nothing selected it shows a muted
/// placeholder instead of the form.
final class SSHHostEditor: NSView {
    override var isFlipped: Bool { true }

    struct Fields {
        var alias = ""
        var hostName = ""
        var user = ""
        var port = ""
    }

    var onCommit: ((Fields) -> Void)?
    var onCancel: (() -> Void)?
    var onDelete: (() -> Void)?
    private let aliasField = ChromeInput(placeholder: "e.g. build-box", icon: "at")
    private let hostNameField = ChromeInput(placeholder: "hostname or IP", icon: "globe")
    private let userField = ChromeInput(placeholder: "ssh user", icon: "person")
    private let portField = ChromeInput(placeholder: "22", icon: "hash")
    private let formContainer = NSView()
    private let placeholderLabel = NSTextField(
        labelWithString: "Select a host to edit — or add one with +")
    private let deleteButton = IconButton.make("trash", pointSize: 11)

    init() {
        super.init(frame: .zero)

        for input in [aliasField, hostNameField, userField, portField] {
            input.onEscape = { [weak self] in self?.onCancel?() }
            input.onReturn = { [weak self] in self?.commit() }
        }

        placeholderLabel.font = .systemFont(ofSize: 12)
        placeholderLabel.textColor = Chrome.theme.secondaryText
        placeholderLabel.cell?.wraps = false
        placeholderLabel.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderLabel)

        formContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(formContainer)

        // Label-above-input rows (tty7 settings geometry): UPPERCASE
        // 10pt semibold label with letter-spacing above a themed input.
        func add(_ title: String, _ input: ChromeInput,
                 top: NSLayoutYAxisAnchor) -> NSLayoutYAxisAnchor {
            let label = NSTextField(labelWithString: "")
            label.attributedStringValue = NSAttributedString(
                string: title.uppercased(),
                attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                             .foregroundColor: Chrome.theme.secondaryText,
                             .kern: 1.1])
            label.translatesAutoresizingMaskIntoConstraints = false
            formContainer.addSubview(label)
            formContainer.addSubview(input)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: formContainer.leadingAnchor, constant: 24),
                label.trailingAnchor.constraint(lessThanOrEqualTo: formContainer.trailingAnchor, constant: -24),
                label.topAnchor.constraint(equalTo: top, constant: 16),
                input.leadingAnchor.constraint(equalTo: formContainer.leadingAnchor, constant: 24),
                input.trailingAnchor.constraint(equalTo: formContainer.trailingAnchor, constant: -24),
                input.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 6),
                input.heightAnchor.constraint(equalToConstant: ControlMetrics.inputHeight),
            ])
            return input.bottomAnchor
        }

        var anchor = formContainer.topAnchor
        anchor = add("Alias", aliasField, top: anchor)
        anchor = add("Host Name", hostNameField, top: anchor)
        anchor = add("User", userField, top: anchor)
        anchor = add("Port", portField, top: anchor)

        formContainer.addSubview(deleteButton)
        let cancel = ChromeButton.make("Cancel", style: .ghost) { [weak self] in
            self?.onCancel?()
        }
        formContainer.addSubview(cancel)

        let save = ChromeButton.make("Save", style: .primary) { [weak self] in
            self?.commit()
        }
        formContainer.addSubview(save)

        NSLayoutConstraint.activate([
            formContainer.topAnchor.constraint(equalTo: topAnchor),
            formContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            formContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            formContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            save.bottomAnchor.constraint(equalTo: formContainer.bottomAnchor, constant: -16),
            save.trailingAnchor.constraint(equalTo: formContainer.trailingAnchor, constant: -20),
            cancel.trailingAnchor.constraint(equalTo: save.leadingAnchor, constant: -8),
            cancel.centerYAnchor.constraint(equalTo: save.centerYAnchor),
            deleteButton.leadingAnchor.constraint(equalTo: formContainer.leadingAnchor, constant: 12),
            deleteButton.centerYAnchor.constraint(equalTo: save.centerYAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant: 26),
            deleteButton.heightAnchor.constraint(equalToConstant: 26),
            placeholderLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        showForm(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder: not implemented") }

    // MARK: State

    /// Fill the form for a host (existing → Delete visible) or a new
    /// one; nil hides the form behind the placeholder.
    func load(fields: Fields?, existing: Bool) {
        guard let fields else {
            showForm(false)
            return
        }
        aliasField.stringValue = fields.alias
        hostNameField.stringValue = fields.hostName
        userField.stringValue = fields.user
        portField.stringValue = fields.port
        deleteButton.isHidden = !existing
        showForm(true)
        aliasField.selectAllText()
    }

    private func showForm(_ on: Bool) {
        formContainer.isHidden = !on
        placeholderLabel.isHidden = on
    }

    func commit() {
        onCommit?(Fields(alias: aliasField.stringValue,
                         hostName: hostNameField.stringValue,
                         user: userField.stringValue,
                         port: portField.stringValue))
    }

    // Test surface (headless harness).
    func typeForTest(_ fields: Fields) {
        aliasField.stringValue = fields.alias
        hostNameField.stringValue = fields.hostName
        userField.stringValue = fields.user
        portField.stringValue = fields.port
    }
    func commitForTest() { commit() }
    var fieldTextForTest: Fields {
        Fields(alias: aliasField.stringValue, hostName: hostNameField.stringValue,
               user: userField.stringValue, port: portField.stringValue)
    }
}

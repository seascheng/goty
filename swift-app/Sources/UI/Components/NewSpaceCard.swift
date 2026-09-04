// goty — see CLAUDE.md for the working principles.
import AppKit

/// The SPACES header's "+": pick a directory, open a space there.
/// Local gets a path input with an NSOpenPanel browse button; remote
/// validates through the existing ssh exec channel (`test -d`) and
/// reports missing paths inline — no tab until the path is real.
/// Chassis: DialogCard (Esc/Return routing) + presentCard, the
/// PromptCard/WorktreeCard family — one dialog design, no second.
final class NewSpaceCard: DialogCard {
    static let cardWidth: CGFloat = 380

    private let host: String?
    private let onConfirm: (String) -> Void
    private let statusLabel = NSTextField(labelWithString: "")
    private let field: ChromeInput
    private var panel: NSPanel? { window as? NSPanel }

    init(host: String?, onConfirm: @escaping (String) -> Void) {
        self.host = host
        self.onConfirm = onConfirm
        field = ChromeInput(placeholder: host == nil ? "~/projects/foo" : "/srv/project")

        super.init(frame: .zero)

        let titleLabel = NSTextField(labelWithString: "New Space")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = Chrome.theme.foreground
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = Chrome.theme.secondaryText
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        // Local: a system directory picker beside the input. Remote
        // paths are typed — the exec validation below is the check.
        var previous: NSView = field
        if host == nil {
            let browse = ChromeButton.make("浏览…", style: .ghost) { [weak self] in
                self?.browse()
            }
            addSubview(browse)
            NSLayoutConstraint.activate([
                browse.centerYAnchor.constraint(equalTo: field.centerYAnchor),
                browse.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            ])
            field.trailingAnchor.constraint(equalTo: browse.leadingAnchor, constant: -8).isActive = true
            previous = field
        }

        let cancel = ChromeButton.make("Cancel", style: .ghost) { [weak self] in
            self?.onCancel?()
        }
        let create = ChromeButton.make("Create", style: .primary) { [weak self] in
            self?.validateAndCreate()
        }
        create.keyEquivalent = "\r"
        addSubview(cancel)
        addSubview(create)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            field.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
        ])
        if host != nil {
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20).isActive = true
        }
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            cancel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            cancel.trailingAnchor.constraint(equalTo: create.leadingAnchor, constant: -8),
            create.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            create.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
        ])

        onPrimary = { [weak self] in self?.validateAndCreate() }
        onCancel = { [weak self] in
            NSApp.stopModal()
            self?.panel?.orderOut(nil)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // MARK: - Path logic (pure, testable)

    /// "~" expands against the local home; remote paths pass through.
    static func expanded(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed == "~" { return NSHomeDirectory() }
        if trimmed.hasPrefix("~/") {
            return NSHomeDirectory() + String(trimmed.dropFirst(1))
        }
        return trimmed
    }

    static func validLocal(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Focus the path field (presentCard's focus closure).
    func focusInput() { _ = field.becomeFirstResponder() }
    // MARK: - Actions

    private func browse() {
        let open = NSOpenPanel()
        open.canChooseFiles = false
        open.canChooseDirectories = true
        open.canCreateDirectories = false
        open.prompt = "Choose"
        if open.runModal() == .OK, let url = open.url {
            field.stringValue = url.path
            statusLabel.stringValue = ""
        }
    }

    private func validateAndCreate() {
        let path = Self.expanded(field.stringValue)
        guard !path.isEmpty, path != "." else {
            statusLabel.textColor = Chrome.theme.dangerFill
            statusLabel.stringValue = "输入一个目录路径"
            return
        }
        if host == nil {
            if Self.validLocal(path) { finish(path) } else {
                statusLabel.textColor = Chrome.theme.dangerFill
                statusLabel.stringValue = "目录不存在：\(path)"
            }
            return
        }
        // Remote: `test -d` over the existing ssh exec channel.
        statusLabel.textColor = Chrome.theme.secondaryText
        statusLabel.stringValue = "校验中…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = Shell.exec("test -d " + Shell.quotedPath(path), host: self?.host).code == 0
            DispatchQueue.main.async {
                guard let self else { return }
                if ok { self.finish(path) } else {
                    self.statusLabel.textColor = Chrome.theme.dangerFill
                    self.statusLabel.stringValue = "远端目录不存在：\(path)"
                }
            }
        }
    }

    private func finish(_ path: String) {
        onConfirm(path)
        NSApp.stopModal()
        panel?.orderOut(nil)
    }
}

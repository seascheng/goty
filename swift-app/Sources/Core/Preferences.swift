// goty — see CLAUDE.md for the working principles.
import Foundation

// MARK: - App preferences (the one typed seam for app-owned settings)

/// Layout chrome lives here; terminal look (colors/font/theme) is owned by
/// the user's Ghostty config (surfaced via ChromeTheme); workspace state
/// (tabs/panes/focus) lives in state.json. A config window binds THIS

/// Which right-panel tab is showing — layout chrome, so it persists.
enum RightPanelTab: String {
    case info, files, git
}
/// store — never raw UserDefaults strings scattered in the delegate.
final class AppPreferences {
    static let shared = AppPreferences()

    private enum Key {
        static let sidebarCollapsed = "sidebarCollapsed"
        static let serversCollapsed = "serversCollapsed"
        static let foldedSpaces = "foldedSpaces"
        static let editorFontSize = "editorFontSize"
        static let sidebarWidth = "sidebarWidth"
        static let rightPanelVisible = "rightPanelVisible"
        static let rightPanelWidth = "rightPanelWidth"
        static let rightPanelTab = "rightPanelTab"
        static let daemonUpgradeDeclined = "daemonUpgradeDeclined"
        static let aiBaseUrl = "aiBaseUrl"
        static let aiModel = "aiModel"
        static let aiApiType = "aiApiType"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Load once; property observers persist every change.
        sidebarCollapsed = defaults.bool(forKey: Key.sidebarCollapsed)
        serversCollapsed = defaults.bool(forKey: Key.serversCollapsed)
        foldedSpaces = (defaults.data(forKey: Key.foldedSpaces))
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        sidebarWidth = defaults.double(forKey: Key.sidebarWidth) >= 160
            ? defaults.double(forKey: Key.sidebarWidth) : 200
        rightPanelVisible = defaults.bool(forKey: Key.rightPanelVisible)
        let ef = defaults.double(forKey: Key.editorFontSize)
        editorFontSize = (9...24).contains(ef) ? ef : 12.5
        let pw = defaults.double(forKey: Key.rightPanelWidth)
        rightPanelWidth = pw >= 216 ? pw : 260
        let tab = defaults.string(forKey: Key.rightPanelTab)
        rightPanelTab = RightPanelTab(rawValue: tab ?? "") ?? .files
        daemonDeclines = (defaults.data(forKey: Key.daemonUpgradeDeclined))
            .flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
        aiBaseUrl = defaults.string(forKey: Key.aiBaseUrl) ?? ""
        aiModel = defaults.string(forKey: Key.aiModel) ?? ""
        aiApiType = defaults.string(forKey: Key.aiApiType) ?? "openai"
    }

    var sidebarCollapsed: Bool {
        didSet { defaults.set(sidebarCollapsed, forKey: Key.sidebarCollapsed) }
    }
    /// SERVERS rows folded away in the sidebar (the header chevron).
    var serversCollapsed: Bool {
        didSet { defaults.set(serversCollapsed, forKey: Key.serversCollapsed) }
    }
    /// Directory sections (spaces) folded away in the sidebar, by name.
    /// Stale names (renamed/moved dirs) are harmless — no section, no
    /// fold; they never match again.
    var foldedSpaces: [String] {
        didSet { defaults.set(try? JSONEncoder().encode(foldedSpaces),
                              forKey: Key.foldedSpaces) }
    }
    var sidebarWidth: Double {
        didSet { defaults.set(sidebarWidth, forKey: Key.sidebarWidth) }
    }
    var rightPanelVisible: Bool {
        didSet { defaults.set(rightPanelVisible, forKey: Key.rightPanelVisible) }
    }
    var rightPanelWidth: Double {
        didSet { defaults.set(rightPanelWidth, forKey: Key.rightPanelWidth) }
    }

    /// Editor mono size (⌘+ / ⌘- / ⌘0 in the editor; clamped 9…24).
    var editorFontSize: Double {
        didSet { defaults.set(editorFontSize, forKey: Key.editorFontSize) }
    }

    var rightPanelTab: RightPanelTab {
        didSet { defaults.set(rightPanelTab.rawValue, forKey: Key.rightPanelTab) }
    }

    /// Daemon-upgrade prompts the user already DECLINED, by daemon key
    /// ("local" or an ssh host): the reported capability → the prompt is
    /// one nag per daemon build, not one per app launch (the every-launch
    /// restart-dialog report). A different capability re-prompts once.
    private(set) var daemonDeclines: [String: Int] {
        didSet { defaults.set(try? JSONEncoder().encode(daemonDeclines),
                              forKey: Key.daemonUpgradeDeclined) }
    }

    func declineDaemonUpgrade(key: String, capability: Int) {
        daemonDeclines[key] = capability
    }

    // MARK: AI provider (API key lives in the Keychain, not here)

    /// OpenAI-compatible endpoint. Empty = AI feature disabled (spec).
    var aiBaseUrl: String {
        didSet { defaults.set(aiBaseUrl, forKey: Key.aiBaseUrl) }
    }
    var aiModel: String {
        didSet { defaults.set(aiModel, forKey: Key.aiModel) }
    }
    /// Wire protocol of the endpoint: "openai" (chat/completions) or
    /// "anthropic" (messages). Anything else reads as openai.
    var aiApiType: String {
        didSet { defaults.set(aiApiType, forKey: Key.aiApiType) }
    }

    /// True when this exact daemon was already declined — stay silent.
    func daemonUpgradeDeclined(key: String, capability: Int) -> Bool {
        daemonDeclines[key] == capability
    }
}

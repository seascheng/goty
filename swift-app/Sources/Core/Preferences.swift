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
        static let editorFontSize = "editorFontSize"
        static let sidebarWidth = "sidebarWidth"
        static let rightPanelVisible = "rightPanelVisible"
        static let rightPanelWidth = "rightPanelWidth"
        static let rightPanelTab = "rightPanelTab"
        static let daemonUpgradeDeclined = "daemonUpgradeDeclined"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Load once; property observers persist every change.
        sidebarCollapsed = defaults.bool(forKey: Key.sidebarCollapsed)
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
    }

    var sidebarCollapsed: Bool {
        didSet { defaults.set(sidebarCollapsed, forKey: Key.sidebarCollapsed) }
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

    /// True when this exact daemon was already declined — stay silent.
    func daemonUpgradeDeclined(key: String, capability: Int) -> Bool {
        daemonDeclines[key] == capability
    }
}

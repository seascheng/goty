// goty — see CLAUDE.md for the working principles.
import AppKit
import Sparkle

/// Sparkle wrapper. The controller must be CREATED before
/// applicationDidFinishLaunching returns (its contract — the property
/// initializer on AppDelegate does that); starting is explicit so the
/// launch order stays ours. Version checks hit the appcast at
/// SUFeedURL; downloads are EdDSA-verified against SUPublicEDKey
/// (the matching private key lives in this machine's keychain —
/// release.sh signs DMGs with it).
final class UpdaterManager: NSObject {
    static let shared = UpdaterManager()

    private let controller: SPUStandardUpdaterController

    private override init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        super.init()
    }

    func start() {
        controller.startUpdater()
    }

    /// The Goty ▸ menu item's action (Sparkle's standard check window).
    @objc func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(nil)
    }
}

extension UpdaterManager: NSMenuItemValidation {
    /// Pull-based (menu-open): enabled only once the updater is running.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        controller.updater.canCheckForUpdates
    }
}

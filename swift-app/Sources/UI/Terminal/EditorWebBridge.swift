// goty — see CLAUDE.md for the working principles.
import AppKit
import WebKit

/// The editor pane's command routing on the shared `WebBridge`
/// transport: save (⌘S from the page), escape, dirty/cursor/zoom
/// notifications, and markdown-preview link opens.
final class EditorWebBridge: WebBridge {
    var onSave: (() -> Void)?
    var onEscape: (() -> Void)?
    var onDirty: ((Bool) -> Void)?
    var onCursor: ((Int, Int) -> Void)?
    var onZoom: ((_ delta: Int, _ reset: Bool) -> Void)?
    var onLink: ((String) -> Void)?

    override func route(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }
        switch type {
        case "save":
            onSave?()
        case "escape":
            onEscape?()
        case "dirty":
            if let value = message["value"] as? Bool { onDirty?(value) }
        case "cursor":
            if let line = message["line"] as? Int,
               let col = message["col"] as? Int {
                onCursor?(line, col)
            }
        case "zoom":
            let delta = message["delta"] as? Int ?? 0
            let reset = message["reset"] as? Bool ?? false
            onZoom?(delta, reset)
        case "link":
            if let url = message["url"] as? String { onLink?(url) }
        default:
            break
        }
    }
}

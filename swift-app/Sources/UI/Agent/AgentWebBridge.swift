// goty — see CLAUDE.md for the working principles.
import AppKit
import WebKit

/// The agent pane's command routing on the shared `WebBridge`
/// transport: `send`, `stop`, `permission`, `setConfig`, session
/// listing/loading, and `@` file references.
final class AgentWebBridge: WebBridge {
    var onSend: ((String) -> Void)?
    var onStop: (() -> Void)?
    var onSetConfig: ((String, String) -> Void)?
    var onListSessions: (() -> Void)?
    var onLoadSession: ((String) -> Void)?
    var onListFiles: ((@escaping ([String]) -> Void) -> Void)?
    var onPermissionOption: ((String) -> Void)?
    /// 重试 after an errored pane: attach-or-respawn from the user's hand.
    var onReconnect: (() -> Void)?

    override func route(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }
        switch type {
        case "send":
            if let text = message["text"] as? String, !text.isEmpty { onSend?(text) }
        case "stop":
            onStop?()
        case "setConfig":
            if let configId = message["configId"] as? String,
               let value = message["value"] as? String {
                onSetConfig?(configId, value)
            }
        case "listSessions":
            onListSessions?()
        case "loadSession":
            if let sessionId = message["sessionId"] as? String {
                onLoadSession?(sessionId)
            }
        case "permission":
            if let optionId = message["optionId"] as? String {
                onPermissionOption?(optionId)
                push(["type": "permissionResolved"])
            }
        case "reconnect":
            onReconnect?()
        case "listFiles":
            onListFiles? { [weak self] files in
                self?.push(["type": "files", "files": files])
            }
        default:
            break
        }
    }
}

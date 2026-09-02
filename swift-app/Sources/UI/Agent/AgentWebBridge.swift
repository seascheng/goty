// goty — see CLAUDE.md for the working principles.
import AppKit
import WebKit

/// The agent pane's command routing on the shared `WebBridge`
/// transport: `send`, `stop`, `permission`, `setConfig`, session
/// listing/loading, and `@` file references.
final class AgentWebBridge: WebBridge {
    /// mode: "normal" | "steer" | "followUp"; images = composer
    /// attachments ({mimeType, data: base64}), empty for pure text.
    var onSend: ((String, String, [AgentImage]) -> Void)?
    /// Queue-management actions from the dock outbox rows: remove a
    /// queued text, or deliver it immediately as a steer.
    var onQueueRemove: ((String) -> Void)?
    var onQueueSendNow: ((String) -> Void)?
    var onStop: (() -> Void)?
    var onSetConfig: ((String, String) -> Void)?
    var onSetFast: ((Bool) -> Void)?
    var onListSessions: (() -> Void)?
    /// History sentinel reached the top of what the page holds: the
    /// session prepends older entries (tail-first loads).
    var onLoadOlder: (() -> Void)?
    var onLoadSession: ((String) -> Void)?
    var onListFiles: ((@escaping ([String]) -> Void) -> Void)?
    var onPermissionOption: ((String) -> Void)?
    /// 重试 after an errored pane: attach-or-respawn from the user's hand.
    var onReconnect: (() -> Void)?
    var onBranch: ((String) -> Void)?
    /// gooey-pi style: fork from an entry and CONTINUE in a new tab;
    /// this pane stays on the original conversation.
    var onBranchNewPane: ((String) -> Void)?
    var onExport: (() -> Void)?
    var onLogin: (() -> Void)?
    var onStartLogin: ((String) -> Void)?
    var onStats: (() -> Void)?
    override func route(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }
        switch type {
        case "send":
            if let text = message["text"] as? String,
               !text.isEmpty || message["images"] != nil {
                let images = (message["images"] as? [[String: Any]] ?? [])
                    .compactMap(AgentImage.init)
                onSend?(text, (message["mode"] as? String) ?? "normal", images)
            }
        case "stop":
            onStop?()
        case "setConfig":
            if let configId = message["configId"] as? String,
               let value = message["value"] as? String {
                onSetConfig?(configId, value)
            }
        case "setFast":
            if let enabled = message["enabled"] as? Bool {
                onSetFast?(enabled)
            }
        case "loadOlder":
            onLoadOlder?()
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
        case "branch":
            if let entryId = message["entryId"] as? String, !entryId.isEmpty {
                onBranch?(entryId)
            }
        case "branchNewPane":
            if let entryId = message["entryId"] as? String, !entryId.isEmpty {
                onBranchNewPane?(entryId)
            }
        case "export":
            onExport?()
        case "login":
            onLogin?()
        case "startLogin":
            if let providerId = message["providerId"] as? String {
                onStartLogin?(providerId)
            }
        case "queueRemove":
            if let text = message["text"] as? String, !text.isEmpty {
                onQueueRemove?(text)
            }
        case "queueSendNow":
            if let text = message["text"] as? String, !text.isEmpty {
                onQueueSendNow?(text)
            }
        case "stats":
            onStats?()
        default:
            break
        }
    }
}

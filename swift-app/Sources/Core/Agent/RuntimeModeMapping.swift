// goty — see CLAUDE.md for the working principles.
import Foundation

/// goty's four permission tiers mapped onto each backend's native
/// knobs. Pure functions only — adapters paste the dicts into their
/// wire calls. Values copied verbatim from monocode's parity layer
/// (src/lib/harness/codexProtocol.ts runtimeModeToCodexConfig +
/// claudeProtocol.ts buildClaudeSpawnArgs); codex has no mid-session
/// mode API, so the params ride EVERY turn/start, claude switches via
/// the stream-json control protocol (`set_permission_mode`).
enum RuntimeModeMapping {
    /// turn/start params: sandbox takes the OBJECT shape.
    static func codexParams(_ mode: AgentRuntimeMode) -> [String: Any] {
        switch mode {
        case .supervised:
            return ["approvalPolicy": "untrusted",
                    "approvalsReviewer": "user",
                    "sandboxPolicy": ["type": "readOnly"]]
        case .autoEdits:
            return ["approvalPolicy": "on-request",
                    "approvalsReviewer": "user",
                    "sandboxPolicy": ["type": "workspaceWrite"]]
        case .auto:
            return ["approvalPolicy": "on-request",
                    "approvalsReviewer": "auto_review",
                    "sandboxPolicy": ["type": "workspaceWrite"]]
        case .fullAccess:
            return ["approvalPolicy": "never",
                    "approvalsReviewer": "user",
                    "sandboxPolicy": ["type": "dangerFullAccess"]]
        }
    }

    /// The runtimeMode chip's config option — shared by every adapter
    /// that declares `.runtimeModes` (options = all four tiers).
    static func option(current: AgentRuntimeMode) -> AgentConfigOption {
        AgentConfigOption(
            id: "runtimeMode", name: "权限", category: "权限",
            currentValue: current.rawValue,
            options: AgentRuntimeMode.allCases.map { mode in
                AgentConfigChoice(value: mode.rawValue, name: mode.displayName,
                                  description: mode.hint, source: nil)
            })
    }


    /// thread/start params: same tier plus the STRING sandbox spelling.
    static func codexThreadParams(_ mode: AgentRuntimeMode) -> [String: Any] {
        var params = codexParams(mode)
        params["sandbox"] = sandboxString(mode)
        return params
    }

    private static func sandboxString(_ mode: AgentRuntimeMode) -> String {
        switch mode {
        case .supervised: return "read-only"
        case .autoEdits, .auto: return "workspace-write"
        case .fullAccess: return "danger-full-access"
        }
    }

    /// claude permission-mode + the extra spawn argv a cold respawn
    /// needs (only bypass carries a danger flag; the rest need none).
    static func claudeSpawn(_ mode: AgentRuntimeMode) -> (mode: String, extraArgs: [String]) {
        switch mode {
        case .supervised:
            return ("default", [])
        case .autoEdits:
            return ("acceptEdits", [])
        case .auto:
            return ("auto", [])
        case .fullAccess:
            return ("bypassPermissions", ["--allow-dangerously-skip-permissions"])
        }
    }
}

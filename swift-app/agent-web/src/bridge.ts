// bridge.ts — the JS→Swift half of the goty IPC contract, in ONE place.
// (Swift→JS is the zod IncomingEventSchema in store.ts; this union is
// its mirror. AgentWebBridge.route() on the Swift side dispatches
// exactly these `type` values.)

export type HostCommand =
  | { type: "ready" }
  | { type: "pageError"; text: string }
  | { type: "send"; text: string; mode: "normal" | "steer" | "followUp";
      images?: { mimeType: string; data: string }[] }
  | { type: "stop" }
  | { type: "setConfig"; configId: string; value: string }
  | { type: "setFast"; enabled: boolean }
  | { type: "listSessions" }
  | { type: "loadSession"; sessionId: string }
  | { type: "permission"; optionId: string }
  | { type: "reconnect" }
  | { type: "listFiles" }
  | { type: "loadOlder" }
  | { type: "branch"; entryId: string }
  | { type: "branchNewPane"; entryId: string }
  | { type: "export" }
  | { type: "login" }
  | { type: "startLogin"; providerId: string }
  | { type: "queueRemove"; text: string }
  | { type: "queueSendNow"; text: string }
  | { type: "stats" };

declare global {
  interface Window {
    webkit?: { messageHandlers: { goty: { postMessage(cmd: HostCommand): void } } };
  }
}

/// Post one command to the host. Outside a WKWebView (tsc, vitest,
/// plain browser) this is a typed no-op.
export function postToHost(cmd: HostCommand): void {
  window.webkit?.messageHandlers.goty.postMessage(cmd);
}

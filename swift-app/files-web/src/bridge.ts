/// JS → Swift: post commands through the same `goty` message handler
/// the agent page uses (each webview has its own content controller).
export function post(msg: Record<string, unknown>) {
  try {
    window.webkit?.messageHandlers.goty.postMessage(msg);
  } catch (err) {
    console.error("goty(files): post failed", err);
  }
}

declare global {
  interface Window {
    webkit?: { messageHandlers: { goty: { postMessage(msg: unknown): void } } };
  }
}

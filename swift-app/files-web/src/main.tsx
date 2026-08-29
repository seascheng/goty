import React from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import { store } from "./store";
import "./styles.css";

declare global {
  interface Window {
    __goty: {
      push(events: unknown[]): void;
      getText(): string;
    };
    webkit?: { messageHandlers: { goty: { postMessage(msg: unknown): void } } };
  }
}

// Same synchronous-apply contract as agent-web: rAF is suspended for
// occluded webviews, so a queued flush would strand chunk tails.
window.__goty = {
  push(events: unknown[]) {
    try { store.applyAll(events); }
    catch (err) { console.error("goty(files): dropped event batch", err); }
  },
  getText(): string {
    return store.doc.text;
  },
};

const root = createRoot(document.getElementById("root")!);
root.render(<App />);
window.webkit?.messageHandlers.goty.postMessage({ type: "ready" });

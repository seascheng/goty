import React from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import { store } from "./store";
import { post } from "./bridge";
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

// Terminal-parity keys at the DOCUMENT level: zoom and Esc must work in
// every mode (edit, preview, diff) and regardless of CodeMirror focus.
// CodeMirror's own keymap never sees keys while it is hidden, so its
// zoom bindings were removed — this is the one handler.
document.addEventListener("keydown", (e) => {
  if (e.metaKey && !e.altKey && !e.ctrlKey) {
    if (e.key === "=" || e.key === "+" || e.code === "Equal") {
      e.preventDefault();
      post({ type: "zoom", delta: 1 });
      return;
    }
    if (e.key === "-" || e.code === "Minus") {
      e.preventDefault();
      post({ type: "zoom", delta: -1 });
      return;
    }
    if (e.key === "0") {
      e.preventDefault();
      post({ type: "zoom", reset: true });
      return;
    }
  }
  if (e.key === "Escape") {
    // CodeMirror's search panel owns Esc while it is open.
    if (document.querySelector(".cm-panel")) return;
    e.preventDefault();
    post({ type: "escape" });
  }
}, true);

const root = createRoot(document.getElementById("root")!);
root.render(<App />);
window.webkit?.messageHandlers.goty.postMessage({ type: "ready" });

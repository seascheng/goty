import React from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import { store } from "./store";
import "./styles.css";

declare global {
  interface Window {
    __goty: { push(events: unknown[]): void };
    webkit?: { messageHandlers: { goty: { postMessage(msg: unknown): void } } };
  }
}

let queued: unknown[] = [];
let flushScheduled = false;

window.__goty = {
  push(events: unknown[]) {
    queued.push(...events);
    if (flushScheduled) return;
    flushScheduled = true;
    requestAnimationFrame(() => {
      flushScheduled = false;
      for (const event of queued.splice(0)) store.apply(event);
    });
  },
};

const root = createRoot(document.getElementById("root")!);
root.render(<App />);
window.webkit?.messageHandlers.goty.postMessage({ type: "ready" });

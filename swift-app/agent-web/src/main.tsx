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

// Synchronous apply: React 18 batches the subscriber notifications per
// tick, so the old requestAnimationFrame queue bought nothing — and it
// actively stalled: rAF is suspended for occluded webviews, leaving
// events stranded in the queue (the lost-replay-tail bug).
window.__goty = {
  push(events: unknown[]) {
    try { store.applyAll(events); }
    catch (err) { console.error("goty: dropped event batch", err); }
  },
};

const root = createRoot(document.getElementById("root")!);
root.render(<App />);
window.webkit?.messageHandlers.goty.postMessage({ type: "ready" });

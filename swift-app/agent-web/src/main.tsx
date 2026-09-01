import React from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import { store } from "./store";
import { postToHost } from "./bridge";
import "./styles.css";

declare global {
  interface Window {
    __goty: { push(events: unknown[]): void };
  }
}

/// One render crash must not white-screen the pane forever. The push
/// pipeline (window.__goty → store) lives OUTSIDE React and keeps
/// running; 重试 resets the view tree so the still-alive store repaints.
class ErrorBoundary extends React.Component<
  { children: React.ReactNode },
  { failed: boolean }
> {
  state = { failed: false };
  static getDerivedStateFromError() { return { failed: true }; }
  componentDidCatch(err: unknown) {
    console.error("goty: render crashed", err);
    postToHost({ type: "pageError", text: String(err) });
  }
  render() {
    if (!this.state.failed) return this.props.children;
    return (
      <div className="errorBoundary">
        <div>页面渲染出错,事件流仍在接收。</div>
        <button type="button" onClick={() => {
          store.reset();
          this.setState({ failed: false });
        }}>重试</button>
      </div>
    );
  }
}

// Synchronous apply: React 18 batches the subscriber notifications per
// Synchronous apply: React 18 batches the subscriber notifications per
// tick, so the old requestAnimationFrame queue bought nothing — and it
// actively stalled: rAF is suspended for occluded webviews, leaving
// events stranded in the queue (the lost-replay-tail bug). Per-event
// error isolation lives INSIDE applyAll (one batch = one emit); the
// try/catch here is only the last-ditch belt.
window.__goty = {
  push(events: unknown[]) {
    try { store.applyAll(events); }
    catch (err) { console.error("goty: dropped event batch", err); }
  },
};

const root = createRoot(document.getElementById("root")!);
root.render(
  <ErrorBoundary>
    <App />
  </ErrorBoundary>
);
postToHost({ type: "ready" });

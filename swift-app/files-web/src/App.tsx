import { useEffect, useState } from "react";
import { store, type Doc } from "./store";
import { CodeEditor } from "./editor";
import { MarkdownPreview } from "./preview";
import { DiffView } from "./diff";

function useStore() {
  const [, force] = useState(0);
  useEffect(() => store.subscribe(() => force((n) => n + 1)), []);
  return store;
}

export function App() {
  const s = useStore();
  const doc = s.doc;
  // Live preview: while editing, re-render the markdown debounced.
  const [previewText, setPreviewText] = useState(doc.text);
  useEffect(() => {
    if (doc.mode !== "preview") return;
    const t = window.setTimeout(() => setPreviewText(doc.text), 200);
    return () => window.clearTimeout(t);
  }, [doc.mode, doc.text]);

  // Theme vars → CSS custom properties on :root (agent-web contract).
  useEffect(() => {
    const root = document.documentElement;
    for (const [k, v] of Object.entries(s.themeVars)) {
      if (k === "mode") root.dataset.theme = v;
      else root.style.setProperty(`--${k}`, v);
    }
  }, [s.themeVars]);

  const editorHidden = doc.mode !== "edit";
  return (
    <div className="app">
      <div className={"editor-pane" + (editorHidden ? " hidden" : "")}>
        <CodeEditor doc={doc} />
      </div>
      {doc.mode === "preview" &&
        <div className="preview-pane">
          <MarkdownPreview text={previewText} />
        </div>}
      {doc.mode === "diff" &&
        <div className="diff-pane">
          {doc.loading
            ? <div className="diff-empty">Loading diff…</div>
            : <DiffView patch={doc.text} path={doc.path} view={doc.diffView} />}
        </div>}
      {doc.mode === "edit" && doc.loading &&
        <div className="loading-veil">Loading…</div>}
    </div>
  );
}

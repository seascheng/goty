import { useEffect, useRef } from "react";
import { EditorState, Compartment } from "@codemirror/state";
import {
  EditorView, keymap, lineNumbers, highlightActiveLine,
  highlightActiveLineGutter, drawSelection, rectangularSelection,
  crosshairCursor, dropCursor,
} from "@codemirror/view";
import {
  defaultKeymap, history, historyKeymap, indentWithTab,
} from "@codemirror/commands";
import {
  bracketMatching, indentOnInput, syntaxHighlighting, defaultHighlightStyle,
  foldGutter, indentUnit, foldKeymap,
} from "@codemirror/language";
import { closeBrackets, closeBracketsKeymap } from "@codemirror/autocomplete";
import { searchKeymap, highlightSelectionMatches, search } from "@codemirror/search";
import { languageFor } from "./languages";
import { store, type Doc } from "./store";
import { post } from "./bridge";

const languageConf = new Compartment();
const wrapConf = new Compartment();
const themeConf = new Compartment();

export function fontSizeTheme(px: number) {
  return EditorView.theme({
    "&": { fontSize: `${px}px`, height: "100%" },
    ".cm-scroller": {
      fontFamily:
        "ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace",
      lineHeight: "1.5",
    },
    ".cm-content": { paddingBottom: "30vh" },
    ".cm-gutters": {
      backgroundColor: "transparent",
      border: "none",
      color: "var(--fg-extra-muted)",
    },
    ".cm-activeLine": { backgroundColor: "var(--surface1)" },
    ".cm-activeLineGutter": {
      backgroundColor: "var(--surface1)", color: "var(--fg-muted)",
    },
    "&.cm-focused": { outline: "none" },
    ".cm-selectionBackground, ::selection": {
      backgroundColor: "var(--border-accent) !important",
    },
    ".cm-cursor, .cm-dropCursor": { borderLeftColor: "var(--foreground)" },
    ".cm-searchMatch": {
      backgroundColor: "var(--mark-ins)", outline: "1px solid var(--border)",
    },
    ".cm-searchMatch.cm-searchMatch-selected": {
      backgroundColor: "var(--mark-del)",
    },
    ".cm-panels": {
      backgroundColor: "var(--surface1)", color: "var(--foreground)",
      borderTop: "1px solid var(--border)",
    },
    ".cm-panel input, .cm-panel button": {
      background: "var(--surface2)", color: "var(--foreground)",
      border: "1px solid var(--border)", borderRadius: "5px",
      padding: "2px 6px", fontSize: "12px",
    },
    ".cm-foldPlaceholder": {
      backgroundColor: "var(--surface2)", border: "none", color: "var(--fg-muted)",
    },
    ".cm-selectionMatch": { backgroundColor: "var(--mark-ins)" },
  });
}

/// The editor body. ONE EditorView lives for the page's lifetime —
/// hidden (not unmounted) in preview/diff modes so `getText()` always
/// reads the live document and undo history survives toggles.
export function CodeEditor({ doc }: { doc: Doc }) {
  const hostRef = useRef<HTMLDivElement>(null);
  const viewRef = useRef<EditorView | null>(null);
  /// True while the doc-sync effect swaps text — that update is a
  /// load, not an edit; it must not ping dirty.
  const programmatic = useRef(false);

  useEffect(() => {
    const host = hostRef.current!;
    let cursorFrame = 0;
    let dirtyTimer = 0;

    const view = new EditorView({
      state: EditorState.create({
        doc: "",
        extensions: [
          lineNumbers(),
          highlightActiveLineGutter(),
          foldGutter(),
          history(),
          closeBrackets(),
          drawSelection(),
          dropCursor(),
          EditorState.allowMultipleSelections.of(true),
          indentOnInput(),
          indentUnit.of("    "),
          syntaxHighlighting(defaultHighlightStyle, { fallback: true }),
          bracketMatching(),
          rectangularSelection(),
          crosshairCursor(),
          keymap.of([
            { key: "Mod-s", preventDefault: true, run: () => { post({ type: "save" }); return true; } },
            ...closeBracketsKeymap,
            ...searchKeymap,
            ...historyKeymap,
            ...foldKeymap,
            indentWithTab,
            ...defaultKeymap,
          ]),
          languageConf.of([]),
          wrapConf.of([]),
          themeConf.of(fontSizeTheme(13)),
          EditorView.updateListener.of((u) => {
            if (u.docChanged) {
              const text = u.state.doc.toString();
              // Synchronous: getText() on the save path must read the
              // live document, never a stale async copy.
              store.setText(text);
              if (!programmatic.current) store.noteEdit();
            }
            if (u.selectionSet) {
              const head = u.state.selection.main.head;
              const line = u.state.doc.lineAt(head);
              const col = head - line.from + 1;
              cancelAnimationFrame(cursorFrame);
              cursorFrame = requestAnimationFrame(
                () => post({ type: "cursor", line: line.number, col }));
            }
          }),
        ],
      }),
      parent: host,
    });
    viewRef.current = view;
    view.focus();
    return () => {
      window.clearTimeout(dirtyTimer);
      cancelAnimationFrame(cursorFrame);
      view.destroy();
      viewRef.current = null;
    };
  }, []);

  // Doc identity/content swap — includes chunked loads (each chunk
  // grows doc.text while loading). Text ONLY: a keystroke must not
  // rebuild the language support tree.
  useEffect(() => {
    const view = viewRef.current;
    if (!view) return;
    if (view.state.doc.toString() !== doc.text) {
      programmatic.current = true;
      view.dispatch({
        changes: { from: 0, to: view.state.doc.length, insert: doc.text },
        selection: { anchor: 0 },
        scrollIntoView: true,
      });
      programmatic.current = false;
    }
  }, [doc.id, doc.text, doc.loading]);

  // Config flips (wrap toggle, zoom, language identity): reconfigure
  // the compartments WITHOUT touching the document.
  useEffect(() => {
    const view = viewRef.current;
    if (!view) return;
    view.dispatch({
      effects: [
        languageConf.reconfigure(languageFor(doc.path) ?? []),
        wrapConf.reconfigure(doc.wrap ? EditorView.lineWrapping : []),
        themeConf.reconfigure(fontSizeTheme(doc.fontSize)),
      ],
    });
  }, [doc.path, doc.wrap, doc.fontSize]);


  return <div ref={hostRef} className="editor-host" />;
}

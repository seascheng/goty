import { z } from "zod";
import { post } from "./bridge";

/// Swift → JS events (the same `window.__goty.push` contract as
/// agent-web; EditorPanel pushes these). Schema-parsed once at the
/// boundary; Swift fills absent optionals with NSNull().
export type DocMode = "edit" | "preview" | "diff";
export type DiffView = "split" | "unified";

export type Doc = {
  id: number;
  path: string;
  language: string | null;
  isMarkdown: boolean;
  mode: DocMode;
  /// Editor content; the raw unified patch in diff mode.
  text: string;
  /// Chunked assembly: a `load` without text expects `chunk`+`endChunk`.
  loading: boolean;
  wrap: boolean;
  fontSize: number;
  diffView: DiffView;
};

const IncomingEventSchema = z.discriminatedUnion("type", [
  z.object({
    type: z.literal("load"),
    docId: z.number(),
    path: z.string(),
    mode: z.enum(["edit", "preview", "diff"]),
    language: z.string().nullish(),
    isMarkdown: z.boolean(),
    wrap: z.boolean(),
    fontSize: z.number(),
    text: z.string().nullish(),
  }),
  z.object({
    type: z.literal("chunk"),
    docId: z.number(),
    text: z.string(),
  }),
  z.object({ type: z.literal("endChunk"), docId: z.number() }),
  z.object({
    type: z.literal("state"),
    mode: z.enum(["edit", "preview", "diff"]).optional(),
    wrap: z.boolean().optional(),
    fontSize: z.number().optional(),
    diffView: z.enum(["split", "unified"]).optional(),
  }),
  z.object({ type: z.literal("savedAck") }),
  z.object({ type: z.literal("pulling") }),
  z.object({ type: z.literal("focus") }),
  z.object({ type: z.literal("theme"), vars: z.record(z.string(), z.string()) }),
]);

type Listener = () => void;

class Store {
  doc: Doc = {
    id: -1,
    path: "",
    language: null,
    isMarkdown: false,
    mode: "edit",
    text: "",
    loading: false,
    wrap: false,
    fontSize: 13,
    diffView: "split",
  };
  themeVars: Record<string, string> = {};
  focused = false;

  /// Dirty protocol: Swift pulls text (`pulling`), writes, then acks.
  /// Edits AFTER the pull are not in the write — the ack must leave
  /// them reported. Sequence counters make the window exact.
  private editSeq = 0;
  private pulledSeq = 0;
  private dirtyTimer = 0;
  private pageDirty = false;

  private listeners = new Set<Listener>();

  subscribe(fn: Listener): () => void {
    this.listeners.add(fn);
    return () => { this.listeners.delete(fn); };
  }
  private notify() {
    for (const fn of this.listeners) fn();
  }

  applyAll(events: unknown[]) {
    for (const ev of events) {
      const parsed = IncomingEventSchema.safeParse(ev);
      if (!parsed.success) {
        console.error("goty(files): dropped event", parsed.error.issues[0]);
        continue;
      }
      this.apply(parsed.data);
    }
    this.notify();
  }

  private apply(ev: z.infer<typeof IncomingEventSchema>) {
    switch (ev.type) {
      case "theme":
        this.themeVars = ev.vars;
        return;
      case "focus":
        this.focused = true;
        return;
      case "pulling":
        this.pulledSeq = this.editSeq;
        return;
      case "savedAck":
        window.clearTimeout(this.dirtyTimer);
        if (this.editSeq > this.pulledSeq) {
          // Edits landed after the save's text pull: still unsaved.
          if (!this.pageDirty) {
            this.pageDirty = true;
            post({ type: "dirty", value: true });
          }
        } else {
          this.pageDirty = false;
        }
        return;
      case "load": {
        const cached = this.cache.get(ev.docId);
        const text = ev.text != null ? ev.text
          : (ev.docId === this.doc.id && !this.doc.loading ? this.doc.text
                                                           : (cached ?? ""));
        this.cache.set(ev.docId, text);
        this.doc = {
          id: ev.docId,
          path: ev.path,
          language: ev.language ?? null,
          isMarkdown: ev.isMarkdown,
          mode: ev.mode,
          text,
          loading: ev.text == null && cached == null
            && !(ev.docId === this.doc.id && !this.doc.loading),
          wrap: ev.wrap,
          fontSize: ev.fontSize,
          diffView: this.doc.diffView,
        };
        this.pageDirty = false;
        return;
      }
      case "chunk":
        if (ev.docId !== this.doc.id) return;
        this.doc = { ...this.doc, text: this.doc.text + ev.text };
        this.cache.set(ev.docId, this.doc.text);
        return;
      case "endChunk":
        if (ev.docId !== this.doc.id) return;
        this.doc = { ...this.doc, loading: false };
        return;
      case "state": {
        const d = this.doc;
        this.doc = {
          ...d,
          mode: ev.mode ?? d.mode,
          wrap: ev.wrap ?? d.wrap,
          fontSize: ev.fontSize ?? d.fontSize,
          diffView: ev.diffView ?? d.diffView,
        };
        return;
      }
    }
  }

  /// Page-side doc cache: re-activations push `load` without text (the
  /// page's copy is never older than the model's).
  private cache = new Map<number, string>();

  /// The editor mutated the text (typed or programmatically loaded).
  /// Keeps `getText()` honest in every mode — the CM instance stays
  /// mounted even while hidden.
  setText(text: string) {
    if (this.doc.text === text) return;
    this.doc = { ...this.doc, text };
    this.cache.set(this.doc.id, text);
  }

  /// A user edit: bumps the sequence and reports dirty (debounced —
  /// one ping per typing burst, not per keystroke).
  noteEdit() {
    this.editSeq++;
    if (this.pageDirty) return;
    window.clearTimeout(this.dirtyTimer);
    this.dirtyTimer = window.setTimeout(() => {
      this.pageDirty = true;
      post({ type: "dirty", value: true });
    }, 120);
  }
}

export const store = new Store();

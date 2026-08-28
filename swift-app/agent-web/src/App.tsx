import React, { useEffect, useRef, useState, useSyncExternalStore } from "react";
import Markdown from "react-markdown";
import remarkGfm from "remark-gfm";
import rehypeHighlight from "rehype-highlight";
import { store } from "./store";
import type { PlanEntry, ToolCall } from "./store";

/* ——— omp-TUI-style line diff (renderDiff design: ±N gutter, dim context,
   word-level highlight on single-line replacements, … gap collapse) ——— */

type DiffRow = { type: "ctx" | "add" | "del"; oldNum?: number; newNum?: number; text: string };

const DIFF_ROW_CAP = 900;

function lineDiff(oldText: string, newText: string): DiffRow[] {
  const a = oldText.replace(/\n$/, "").split("\n");
  const b = newText.replace(/\n$/, "").split("\n");
  let oldNum = 1;
  let newNum = 1;
  if (a.length > DIFF_ROW_CAP || b.length > DIFF_ROW_CAP) {
    const rows: DiffRow[] = a.map((t) => ({ type: "del", oldNum: oldNum++, text: t }));
    return rows.concat(b.map((t) => ({ type: "add", newNum: newNum++, text: t })));
  }
  const m = a.length;
  const n = b.length;
  const dp = new Uint32Array((m + 1) * (n + 1));
  const at = (i: number, j: number) => i * (n + 1) + j;
  for (let i = m - 1; i >= 0; i--) {
    for (let j = n - 1; j >= 0; j--) {
      dp[at(i, j)] = a[i] === b[j]
        ? dp[at(i + 1, j + 1)] + 1
        : Math.max(dp[at(i + 1, j)], dp[at(i, j + 1)]);
    }
  }
  const rows: DiffRow[] = [];
  const pushDel = (t: string) => rows.push({ type: "del", oldNum: oldNum++, text: t });
  const pushAdd = (t: string) => rows.push({ type: "add", newNum: newNum++, text: t });
  let i = 0;
  let j = 0;
  while (i < m && j < n) {
    if (a[i] === b[j]) { rows.push({ type: "ctx", oldNum: oldNum++, newNum: newNum++, text: a[i] }); i++; j++; }
    else if (dp[at(i + 1, j)] >= dp[at(i, j + 1)]) { pushDel(a[i]); i++; }
    else { pushAdd(b[j]); j++; }
  }
  while (i < m) pushDel(a[i++]);
  while (j < n) pushAdd(b[j++]);
  return rows;
}

/// Word-level split for a 1:1 replaced line: trim the common word
/// prefix/suffix, mark the changed middle. Mirrors omp renderIntraLineDiff.
function wordSegments(oldLine: string, newLine: string): {
  del: Array<{ same: boolean; text: string }>; ins: Array<{ same: boolean; text: string }>;
} {
  const aw = oldLine.split(/(\s+)/);
  const bw = newLine.split(/(\s+)/);
  let pre = 0;
  while (pre < aw.length && pre < bw.length && aw[pre] === bw[pre]) pre++;
  let suf = 0;
  while (suf < aw.length - pre && suf < bw.length - pre && aw[aw.length - 1 - suf] === bw[bw.length - 1 - suf]) suf++;
  const del: Array<{ same: boolean; text: string }> = [];
  const ins: Array<{ same: boolean; text: string }> = [];
  for (let k = 0; k < aw.length; k++) {
    if (k < pre || k >= aw.length - suf) del.push({ same: true, text: aw[k] });
    else del.push({ same: false, text: aw[k] });
  }
  for (let k = 0; k < bw.length; k++) {
    if (k < pre || k >= bw.length - suf) ins.push({ same: true, text: bw[k] });
    else ins.push({ same: false, text: bw[k] });
  }
  return { del, ins };
}

const CTX_COLLAPSE = 10;

function renderRow(row: DiffRow, gutterWidth: number): React.ReactNode {
  const gutter = String(row.oldNum ?? row.newNum ?? "").padStart(gutterWidth);
  if (row.type === "ctx") {
    return (
      <div key={"c" + row.oldNum + "-" + row.newNum + row.text} className="diff-row ctx">
        <span className="ln">{gutter}</span>
        <span className="tx">{row.text || " "}</span>
      </div>
    );
  }
  const cls = row.type === "add" ? "add" : "del";
  return (
    <div key={cls + (row.oldNum ?? 0) + "-" + (row.newNum ?? 0) + row.text} className={"diff-row " + cls}>
      <span className="ln">{gutter}</span>
      <span className="tx">{row.text || " "}</span>
    </div>
  );
}

function DiffBody({ rows }: { rows: DiffRow[] }) {
  const [expanded, setExpanded] = useState<Set<number>>(new Set());
  const gutterWidth = Math.max(3, ...rows.map((r) => String(r.oldNum ?? r.newNum ?? "").length));
  const out: React.ReactNode[] = [];
  let i = 0;
  while (i < rows.length) {
    if (rows[i].type !== "ctx") { out.push(renderRow(rows[i], gutterWidth)); i++; continue; }
    let j = i;
    while (j < rows.length && rows[j].type === "ctx") j++;
    const run = j - i;
    if (run <= CTX_COLLAPSE + 2) {
      for (let k = i; k < j; k++) out.push(renderRow(rows[k], gutterWidth));
    } else if (expanded.has(i)) {
      for (let k = i; k < j; k++) out.push(renderRow(rows[k], gutterWidth));
    } else {
      for (let k = i; k < i + 3; k++) out.push(renderRow(rows[k], gutterWidth));
      const collapsedIdx = i;
      out.push(
        <button key={"gap" + i} className="diff-gap" onClick={() =>
          setExpanded((s) => new Set(s).add(collapsedIdx))}>
          ⋯ {run - 6} 行未更改
        </button>,
      );
      for (let k = j - 3; k < j; k++) out.push(renderRow(rows[k], gutterWidth));
    }
    i = j;
  }
  return <>{out}</>;
}

const editKinds = new Set(["edit", "write", "multiedit", "apply_patch", "patch"]);

function DiffView({ call }: { call: ToolCall }) {
  const raw = call.rawInput ?? {};
  const path = typeof raw.path === "string" ? raw.path : null;
  const newText = typeof raw.content === "string" ? raw.content
    : typeof raw.newText === "string" ? raw.newText : null;
  if (path == null || newText == null) return null;
  const oldText = call.oldText ?? "";
  const rows = lineDiff(oldText, newText);
  const adds = rows.filter((r) => r.type === "add").length;
  const dels = rows.filter((r) => r.type === "del").length;
  return (
    <div className="diff">
      <div className="diff-head">
        <span className="diff-path">{path}</span>
        <span className="diff-stats"><span className="stat-add">+{adds}</span> <span className="stat-del">−{dels}</span></span>
      </div>
      <div className="diff-body"><DiffBody rows={rows} /></div>
    </div>
  );
}

const STATUS_ICON: Record<string, string> = {
  pending: "○", in_progress: "◐", completed: "✓", error: "✗",
};

function ToolCard({ id }: { id: string }) {
  const call = store.tools.get(id)!;
  const isDiff = call.kind != null && editKinds.has(call.kind);
  const [open, setOpen] = useState(call.status === "in_progress" || isDiff);
  const running = call.status === "in_progress" || call.status === "pending";
  const icon = STATUS_ICON[call.status ?? ""] ?? "○";
  const statusLabel = call.status === "completed" ? "完成"
    : call.status === "in_progress" ? "运行中"
    : call.status === "pending" ? "等待"
    : call.status === "error" ? "出错"
    : (call.status ?? "");
  const showDiff = isDiff || (call.rawInput?.content != null);
  const textContent = call.content.filter((c) => c.text).map((c) => c.text).join("\n");
  return (
    <div className={"tool" + (open ? " open" : "") + (running ? " run" : "")}>
      <button className="tool-head" onClick={() => setOpen(!open)}>
        <span className={"chevron" + (open ? " up" : "")}>▸</span>
        <span className={"tool-icon " + (call.status ?? "")}>{icon}</span>
        <span className="tool-title">{toolDisplayTitle(call)}</span>
        <span className={"tool-status" + (running ? " running" : "")}>{statusLabel}</span>
      </button>
      {open && (
        <div className="tool-body">
          {showDiff && <DiffView call={call} />}
          {!showDiff && call.content.map((c, j) => c.text
            ? <pre key={j}><code>{c.text}</code></pre>
            : c.path ? <div key={j} className="tool-path">{c.path}</div> : null)}
          {!showDiff && textContent === "" && (call.rawInput != null) && (
            <pre><code>{JSON.stringify(call.rawInput, null, 1)}</code></pre>
          )}
        </div>
      )}
    </div>
  );
}

function PlanCard({ entries }: { entries: PlanEntry[] }) {
  const done = entries.filter((e) => e.status === "completed").length;
  return (
    <div className="plan">
      <div className="plan-head">
        <span className="plan-title">计划</span>
        <span className="plan-progress">{done}/{entries.length}</span>
      </div>
      {entries.map((e, j) => (
        <div key={j} className={"plan-row " + (e.status ?? "")}>
          <span className="plan-mark">{e.status === "completed" ? "✓" : e.status === "in_progress" ? "◐" : "○"}</span>
          <span>{e.content}</span>
        </div>
      ))}
    </div>
  );
}

function fmtTokens(n?: number | null): string {
  if (n == null) return "";
  return n >= 1000 ? (n / 1000).toFixed(1) + "k" : String(n);
}

/// One clickable config knob (mode / model / thinking …) with its option
/// popover. Selection posts `setConfig`; the OK response re-syncs the
/// whole knob list, so this component is stateless about current values.
/// Minimal 24px stroke icons (lucide-style geometry, no dependency).
function Icon({ kind }: { kind: "history" | "model" | "mode" | "thinking" | "stop" | "send" }) {
  const common = { width: 13, height: 13, viewBox: "0 0 24 24", fill: "none",
                   stroke: "currentColor", strokeWidth: 2,
                   strokeLinecap: "round" as const, strokeLinejoin: "round" as const };
  switch (kind) {
    case "history":
      return <svg {...common}><circle cx="12" cy="12" r="9" /><path d="M12 7v5l3 2" /><path d="M3 12a9 9 0 1 0 3-6.7L3 8" /><path d="M3 3v5h5" /></svg>;
    case "model":
      return <svg {...common}><path d="M13 2 4 14h6l-1 8 9-12h-6l1-8z" /></svg>;
    case "mode":
      return <svg {...common}><circle cx="12" cy="12" r="9" /><path d="M15.5 8.5 10 10l-1.5 5.5L14 13.5z" /></svg>;
    case "thinking":
      return <svg {...common}><path d="M3 12h4l3-8 4 16 3-8h4" /></svg>;
    case "stop":
      return <svg {...common}><rect x="6" y="6" width="12" height="12" rx="2" fill="currentColor" stroke="none" /></svg>;
    case "send":
      return <svg {...common}><path d="M12 19V5" /><path d="M5 12l7-7 7 7" /></svg>;
  }
}

/// What the tool row shows as its title. Agent titles win (omp's "占位"
/// placeholder does not); otherwise derive from kind + rawInput path.
function toolDisplayTitle(call: ToolCall): string {
  if (call.title && call.title !== "占位") return call.title;
  const path = typeof call.rawInput?.path === "string" ? call.rawInput.path : null;
  const base = path ? path.split("/").pop() : null;
  const kindLabel = call.kind === "read" ? "Read"
    : call.kind === "search" ? "Search"
    : call.kind === "edit" || call.kind === "write" ? "Edit"
    : call.kind === "execute" || call.kind === "bash" ? "Run"
    : call.kind;
  if (kindLabel) return base ? `${kindLabel} ${base}` : kindLabel;
  if (base) return base;
  return call.id;
}

function ConfigChip({ option, icon, open, onToggle, onPick }: {
  option: { id: string; name: string; currentValue?: string | null;
            options: { value: string; name: string }[] };
  icon: React.ReactNode;
  open: boolean; onToggle: () => void; onPick: (value: string) => void;
}) {
  const current = option.options.find((o) => o.value === option.currentValue);
  return (
    <div className="chip-wrap">
      <button className={"chip" + (open ? " open" : "")} onClick={onToggle} title={option.name}>
        {icon}
        <span className="chip-value">{current?.name ?? option.currentValue ?? "—"}</span>
        <span className="chip-caret">▾</span>
      </button>
      {open && (
        <div className="chip-pop">
          {option.options.map((o) => (
            <button key={o.value}
              className={"chip-opt" + (o.value === option.currentValue ? " cur" : "")}
              onClick={() => onPick(o.value)}>
              <span>{o.name}</span>
              {o.value === option.currentValue && <span className="chip-check">✓</span>}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

function HistoryChip() {
  const [open, setOpen] = useState(false);
  return (
    <div className="chip-wrap">
      <button className={"chip" + (open ? " open" : "")} title="历史会话"
        onClick={() => {
          setOpen(!open);
          if (!open) window.webkit?.messageHandlers.goty.postMessage({ type: "listSessions" });
        }}>
        <Icon kind="history" />
        <span className="chip-value">历史</span>
        <span className="chip-caret">▾</span>
      </button>
      {open && (
        <div className="chip-pop">
          {store.sessions.length === 0 && <div className="slash-desc">无会话记录</div>}
          {store.sessions.map((s) => (
            <button key={s.sessionId} className="chip-opt hist"
              onClick={() => {
                window.webkit?.messageHandlers.goty.postMessage({ type: "loadSession", sessionId: s.sessionId });
                store.apply({ type: "clearTranscript" });
                setOpen(false);
              }}>
              <span className="hist-title">{s.title ?? s.sessionId.slice(0, 8)}</span>
              <span className="hist-meta">{s.messageCount != null ? `${s.messageCount} 条` : ""}</span>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

function Composer({ working }: { working: boolean }) {
  const [text, setText] = useState("");
  const [openChip, setOpenChip] = useState<string | null>(null);
  const [slashIndex, setSlashIndex] = useState(0);
  const [atIndex, setAtIndex] = useState(0);
  const ref = useRef<HTMLTextAreaElement>(null);

  const slashQuery = /^\/[\w-]*$/.test(text) ? text.slice(1).toLowerCase() : null;
  const slashMatches = slashQuery == null ? [] :
    store.commands.filter((c) => c.name.toLowerCase().startsWith(slashQuery));
  const slashOpen = slashQuery != null && slashMatches.length > 0;

  const atMatch = /@([\w./-]*)$/.exec(text);
  const atOpen = atMatch != null;
  const atQuery = (atMatch?.[1] ?? "").toLowerCase();
  const atMatches = atOpen
    ? store.files.filter((f) => f.toLowerCase().includes(atQuery)).slice(0, 8)
    : [];

  useEffect(() => {
    if (atOpen && store.files.length === 0) {
      window.webkit?.messageHandlers.goty.postMessage({ type: "listFiles" });
    }
  }, [atOpen]);

  const pickSlash = (name: string) => {
    setText("/" + name + " ");
    ref.current?.focus();
  };

  const pickAt = (file: string) => {
    setText(text.replace(/@([\w./-]*)$/, "@" + file + " "));
    ref.current?.focus();
  };

  const pickConfig = (configId: string, value: string) => {
    window.webkit?.messageHandlers.goty.postMessage({ type: "setConfig", configId, value });
    setOpenChip(null);
  };


  const submit = () => {
    const trimmed = text.trim();
    if (!trimmed || working) return;
    window.webkit?.messageHandlers.goty.postMessage({ type: "send", text: trimmed });
    store.apply({ type: "userMessage", text: trimmed });
    setText("");
    ref.current?.style.setProperty("height", "auto");
  };

  const onComposerKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.nativeEvent.isComposing) return;
    if (atOpen && atMatches.length > 0) {
      if (e.key === "ArrowDown") { e.preventDefault(); setAtIndex((i) => (i + 1) % atMatches.length); return; }
      if (e.key === "ArrowUp") { e.preventDefault(); setAtIndex((i) => (i - 1 + atMatches.length) % atMatches.length); return; }
      if (e.key === "Enter" || e.key === "Tab") {
        e.preventDefault(); pickAt(atMatches[atIndex]); return;
      }
      if (e.key === "Escape") { e.preventDefault(); setText(""); return; }
    }
    if (e.key === "Escape" && working && !slashOpen && atMatches.length === 0) {
      e.preventDefault();
      window.webkit?.messageHandlers.goty.postMessage({ type: "stop" });
      return;
    }
    if (slashOpen) {
      if (e.key === "ArrowDown") { e.preventDefault(); setSlashIndex((i) => (i + 1) % slashMatches.length); return; }
      if (e.key === "ArrowUp") { e.preventDefault(); setSlashIndex((i) => (i - 1 + slashMatches.length) % slashMatches.length); return; }
      if (e.key === "Enter" || e.key === "Tab") {
        e.preventDefault(); pickSlash(slashMatches[slashIndex].name); return;
      }
      if (e.key === "Escape") { e.preventDefault(); setText(""); return; }
    }
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      submit();
    }
  };

  return (
    <div className="composer">
      <div className="composer-box">
        <textarea
          ref={ref}
          value={text}
          rows={1}
          placeholder="Message the agent…  (Enter 发送，/ 指令，@ 引用文件)"
          onChange={(e) => {
            setText(e.target.value);
            setSlashIndex(0);
            setAtIndex(0);
            const el = e.target;
            el.style.height = "auto";
            el.style.height = Math.min(el.scrollHeight, 140) + "px";
          }}
          onKeyDown={onComposerKeyDown}
        />
        {atOpen && atMatches.length > 0 && (
          <div className="slash-pop">
            {atMatches.map((f, i) => (
              <button key={f}
                className={"slash-opt" + (i === atIndex ? " cur" : "")}
                onMouseEnter={() => setAtIndex(i)}
                onClick={() => pickAt(f)}>
                <span className="slash-name">@{f}</span>
              </button>
            ))}
          </div>
        )}
        {slashOpen && (
          <div className="slash-pop">
            {slashMatches.map((c, i) => (
              <button key={c.name}
                className={"slash-opt" + (i === slashIndex ? " cur" : "")}
                onMouseEnter={() => setSlashIndex(i)}
                onClick={() => pickSlash(c.name)}>
                <span className="slash-name">/{c.name}</span>
                {c.inputHint && <span className="slash-hint">{c.inputHint}</span>}
                {c.description && <span className="slash-desc">{c.description}</span>}
              </button>
            ))}
          </div>
        )}
      </div>
      <div className="composer-toolbar">
        <div className="toolbar-left">
          <HistoryChip />
          {store.configOptions.map((option) => (
            <ConfigChip key={option.id} option={option}
              icon={<Icon kind={option.id === "thinking" ? "thinking" : option.id === "mode" ? "mode" : "model"} />}
              open={openChip === option.id}
              onToggle={() => setOpenChip(openChip === option.id ? null : option.id)}
              onPick={(value) => pickConfig(option.id, value)} />
          ))}
        </div>
        <div className="toolbar-right">
          {store.usage && (store.usage.used != null || store.usage.costAmount != null) && (
            <span className="usage">
              {store.usage.used != null && <>↑{fmtTokens(store.usage.used)}</>}
              {store.usage.size != null && <> / {fmtTokens(store.usage.size)}</>}
              {store.usage.costAmount != null && <> · ${store.usage.costAmount.toFixed(4)}</>}
            </span>
          )}
          <span className={"status-dot " + (working ? "working" : "")} />
          <button
            className={"action-btn " + (working ? "stop" : "send")}
            disabled={!working && !text.trim()}
            title={working ? "停止 (Esc)" : "发送 (Enter)"}
            onClick={() => working
              ? window.webkit?.messageHandlers.goty.postMessage({ type: "stop" })
              : submit()}>
            <Icon kind={working ? "stop" : "send"} />
          </button>
        </div>
      </div>
    </div>
  );
}

export function App() {
  useSyncExternalStore(
    (onChange) => store.subscribe(onChange),
    () => store.revision,
  );
  const scroller = useRef<HTMLDivElement>(null);
  const pinned = useRef(true);

  useEffect(() => {
    if (pinned.current) scroller.current?.scrollTo(0, scroller.current.scrollHeight);
  });

  const onScroll = () => {
    const el = scroller.current!;
    pinned.current = el.scrollHeight - el.scrollTop - el.clientHeight < 40;
  };

  return (
    <div className="pane">
      <div className="transcript" ref={scroller} onScroll={onScroll}>
        {store.blocks.map((block, i) => {
          switch (block.kind) {
            case "user": return <div key={i} className="user-row"><div className="user">{block.text}</div></div>;
            case "agent": return block.text ? (
              <div key={i} className="agent"><Markdown remarkPlugins={[remarkGfm]}
                rehypePlugins={[rehypeHighlight]}>{block.text}</Markdown></div>) : null;
            case "thought": return <div key={i} className="thought">{block.text}</div>;
            case "tool": return <ToolCard key={i} id={block.call.id} />;
            case "plan": return <PlanCard key={i} entries={block.entries} />;
          }
        })}
      </div>
      {store.permission && (
        <div className="permission">
          <div className="perm-title">{store.permission.toolCallTitle ?? "需要授权"}</div>
          <div className="perm-options">
            {store.permission.options.map((o) => (
              <button key={o.optionId}
                className={"btn " + (o.kind?.startsWith("allow") ? "send" : "")}
                onClick={() => window.webkit?.messageHandlers.goty.postMessage(
                  { type: "permission", optionId: o.optionId })}>
                {o.name}
              </button>
            ))}
          </div>
        </div>
      )}
      <Composer working={store.working} />
    </div>
  );
}

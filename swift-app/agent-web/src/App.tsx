import React, { useEffect, useLayoutEffect, useRef, useState, useSyncExternalStore } from "react";
import Markdown from "react-markdown";
import remarkGfm from "remark-gfm";
import rehypeHighlight from "rehype-highlight";
import { store, type Block, type PlanEntry, type ToolCall } from "./store";

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

const KNOB_ORDER: Record<string, number> = { model: 0, thinking: 1, mode: 2 };

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
          {call.output.length > 0 && (
            <>
              <div className="tool-out-label">输出</div>
              {call.output.map((c, j) => c.text
                ? <pre key={"o" + j}><code>{c.text}</code></pre>
                : c.path ? <div key={"o" + j} className="tool-path">{c.path}</div> : null)}
            </>
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
  if (n >= 1e9) return (n / 1e9).toFixed(1).replace(/\.0$/, "") + "G";
  if (n >= 1e6) return (n / 1e6).toFixed(1).replace(/\.0$/, "") + "M";
  if (n >= 1000) return (n / 1000).toFixed(1).replace(/\.0$/, "") + "k";
  return String(n);
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

/// Untitled sessions: omp names them asynchronously, so fresh ones have
/// no title yet — show the activity timestamp instead of a raw hex id.
function histFallback(s: { updatedAt?: string | null }): string {
  if (!s.updatedAt) return "未命名会话";
  const d = new Date(s.updatedAt);
  if (isNaN(d.getTime())) return "未命名会话";
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function HistoryChip({ open, onToggle, onSelect }: {
  open: boolean; onToggle: () => void; onSelect: (sessionId: string) => void;
}) {
  return (
    <div className="chip-wrap">
      <button className={"chip" + (open ? " open" : "")} title="历史会话" onClick={onToggle}>
        <Icon kind="history" />
        <span className="chip-value">历史</span>
        <span className="chip-caret">▾</span>
      </button>
      {open && (
        <div className="chip-pop">
          {store.sessions.length === 0 && <div className="slash-desc">无会话记录</div>}
          {store.sessions.map((s) => (
            <button key={s.sessionId} className="chip-opt hist"
              onClick={() => onSelect(s.sessionId)}>
              <span className="hist-title">{s.title || histFallback(s)}</span>
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
  const [openPop, setOpenPop] = useState<string | null>(null);
  const [histOpen, setHistOpen] = useState(false);
  const [slashIndex, setSlashIndex] = useState(0);
  const [atIndex, setAtIndex] = useState(0);
  const [dismissed, setDismissed] = useState(false);
  const [hist, setHist] = useState<string[]>([]);
  const histIdx = useRef<number | null>(null);
  const ref = useRef<HTMLTextAreaElement>(null);
  const boxRef = useRef<HTMLDivElement>(null);

  // Boot focus (DOM side): the app focuses the webview (responder
  // level); without this the page's activeElement stays BODY and every
  // keystroke dies — the "restored pane ignores the keyboard" report.
  // Chat-surface convention: the composer is where typing goes.
  useEffect(() => {
    ref.current?.focus();
  }, []);

  const atMatch = /@([\w./-]*)$/.exec(text);
  const atOpen = atMatch != null && !dismissed;
  const slashQuery = /^\/[\w-]*$/.test(text) ? text.slice(1).toLowerCase() : null;
  const slashMatches = slashQuery == null ? [] :
    store.commands.filter((c) => c.name.toLowerCase().startsWith(slashQuery));
  // Opens even on zero matches: a silent no-op on "/" hid the feature
  // entirely on agents without a command directory (codex pre-skills).
  const slashOpen = slashQuery != null && !dismissed && !atOpen;

  const atQuery = (atMatch?.[1] ?? "").toLowerCase();
  const atMatches = atOpen
    ? store.files.filter((f) => f.toLowerCase().includes(atQuery)).slice(0, 8)
    : [];

  useEffect(() => {
    if (atOpen && store.files.length === 0) {
      window.webkit?.messageHandlers.goty.postMessage({ type: "listFiles" });
    }
  }, [atOpen]);

  // Any mousedown that is not on the OPEN popover closes it. Clicks
  // outside the whole composer additionally dismiss the @// popups
  // (typing re-arms them).
  useEffect(() => {
    const onDown = (e: MouseEvent) => {
      const target = e.target as Element;
      const inBox = boxRef.current != null && boxRef.current.contains(target);
      if (inBox && target.closest(".chip-wrap") != null) return;
      setOpenPop(null);
      setHistOpen(false);
      if (!inBox) setDismissed(true);
    };
    document.addEventListener("mousedown", onDown);
    return () => document.removeEventListener("mousedown", onDown);
  }, []);

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
    setOpenPop(null);
  };


  const submit = () => {
    const trimmed = text.trim();
    if (!trimmed || working) return;
    window.webkit?.messageHandlers.goty.postMessage({ type: "send", text: trimmed });
    store.apply({ type: "userMessage", text: trimmed });
    setHist((h) => (h[h.length - 1] === trimmed ? h : [...h, trimmed]));
    histIdx.current = null;
    setText("");
    ref.current?.style.setProperty("height", "auto");
  };

  const onComposerKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    // TUI-style input recall: empty composer + ↑/↓ walks the history
    // of sent inputs (↑ = older; ↓ past the newest clears back to empty).
    if ((e.key === "ArrowUp" || e.key === "ArrowDown") && hist.length > 0
        && (text === "" || histIdx.current != null)) {
      e.preventDefault();
      const last = hist.length - 1;
      if (e.key === "ArrowUp") {
        histIdx.current = histIdx.current == null ? last : Math.max(0, histIdx.current - 1);
      } else if (histIdx.current == null) {
        return;
      } else if (histIdx.current >= last) {
        histIdx.current = null;
        setText("");
        return;
      } else {
        histIdx.current += 1;
      }
      const recalled = hist[histIdx.current];
      setText(recalled);
      requestAnimationFrame(() => {
        const el = ref.current;
        if (el) el.setSelectionRange(el.value.length, el.value.length);
      });
      return;
    }
    if (e.key === "ArrowUp" || e.key === "ArrowDown") {
      if (atOpen) {
      if (e.key === "ArrowDown") { e.preventDefault(); setAtIndex((i) => (i + 1) % atMatches.length); return; }
      if (e.key === "ArrowUp") { e.preventDefault(); setAtIndex((i) => (i - 1 + atMatches.length) % atMatches.length); return; }
      if (e.key === "Enter" || e.key === "Tab") {
        e.preventDefault(); pickAt(atMatches[atIndex]); return;
      }
      if (e.key === "Escape") { e.preventDefault(); setText(""); return; }
      }
    }
    if (e.key === "Escape") {
      if (openPop != null || histOpen) { setOpenPop(null); setHistOpen(false); return; }
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
      <div className="composer-box" ref={boxRef}>
        <textarea
          ref={ref}
          value={text}
          rows={1}
          placeholder="Message the agent…  (Enter 发送，/ 指令，@ 引用文件)"
          onChange={(e) => {
            setText(e.target.value);
            setSlashIndex(0);
            setAtIndex(0);
            setDismissed(false);
            histIdx.current = null;
            const el = e.target;
            el.style.height = "auto";
            el.style.height = Math.min(el.scrollHeight, 160) + "px";
          }}
          onKeyDown={onComposerKeyDown}
        />
        {atOpen && atMatches.length > 0 && (
          <div className="slash-pop">
            {atMatches.map((f, i) => (
              <button key={f}
                ref={(el) => { if (i === atIndex && el) el.scrollIntoView({ block: "nearest" }); }}
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
            {slashMatches.length === 0 && (
              <div className="slash-desc">
                {store.commands.length === 0
                  ? "该 agent 暂无可用指令目录"
                  : `无匹配“${slashQuery}”的指令`}
              </div>
            )}
            {slashMatches.map((c, i) => (
              <button key={c.name}
                ref={(el) => { if (i === slashIndex && el) el.scrollIntoView({ block: "nearest" }); }}
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
      <div className="composer-toolbar">
        <div className="toolbar-left">
          {store.meta?.icon && (
            <img className="pane-agent-icon" src={store.meta.icon}
                 alt="" draggable={false} />
          )}
          <HistoryChip open={histOpen}
            onToggle={() => {
              const next = !histOpen;
              setHistOpen(next);
              setOpenPop(next ? null : openPop);
              if (next) window.webkit?.messageHandlers.goty.postMessage({ type: "listSessions" });
            }}
            onSelect={(sessionId) => {
              window.webkit?.messageHandlers.goty.postMessage({ type: "loadSession", sessionId });
              store.apply({ type: "clearTranscript" });
              setHistOpen(false);
            }} />
          {store.starting && (
            <span className="chip starting" title="agent 进程已启动，握手完成前模型/思考等控件不可用">
              <span className="spin" />
              <span className="chip-value">正在启动 {store.starting}…</span>
            </span>
          )}
          {[...store.configOptions]
            .sort((a, b) => (KNOB_ORDER[a.id] ?? 9) - (KNOB_ORDER[b.id] ?? 9))
            .map((option) => (
            <ConfigChip key={option.id} option={option}
              icon={<Icon kind={option.id === "thinking" ? "thinking" : option.id === "mode" ? "mode" : "model"} />}
              open={openPop === option.id}
              onToggle={() => setOpenPop(openPop === option.id ? null : option.id)}
              onPick={(value) => pickConfig(option.id, value)} />
            ))}
            {store.meta?.directory && (
              <span className="pane-meta">
                {[store.meta.workspace, store.meta.directory].filter(Boolean).join("/")}
                {store.meta.branch ? ` · ${store.meta.branch}` : ""}
              </span>
            )}
          </div>
        <div className="toolbar-right">
          {(() => {
            const u = store.usage;
            if (!u) return null;
            // Full-set statusbar segments; an agent that can't supply a
            // piece simply hides that segment.
            const parts: string[] = [];
            if (u.input != null) parts.push(`↑${fmtTokens(u.input)}`);
            if (u.output != null) parts.push(`↓${fmtTokens(u.output)}`);
            if (u.used != null && u.size != null && u.size > 0) {
              parts.push(`${((u.used / u.size) * 100).toFixed(1)}%/${fmtTokens(u.size)}`);
            } else if (u.used != null) {
              parts.push(`↑${fmtTokens(u.used)}`);
            }
            if (u.costAmount != null) {
              parts.push(`$${u.costAmount < 1 ? u.costAmount.toFixed(4) : u.costAmount.toFixed(2)}`);
            }
            if (parts.length === 0) return null;
            return <span className="usage">{parts.join(" · ")}</span>;
          })()}
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
    </div>
  );
}

const INITIAL_WINDOW = 60;
const WINDOW_PAGE = 150;

/// One transcript row. Memoized: during replay only the newest blocks
/// change identity, so scroll-up pagination re-renders just the newly
/// revealed rows and streaming re-renders only the tail block.
const BlockView = React.memo(
  function BlockView({ block }: { block: Block }) {
    switch (block.kind) {
      case "user": return <div className="user-row"><div className="user">{block.text}</div></div>;
      case "agent": return block.text ? (
        <div className="agent"><Markdown remarkPlugins={[remarkGfm]}
          rehypePlugins={[rehypeHighlight]}>{block.text}</Markdown></div>) : null;
      case "thought": return <div className="thought"><Markdown remarkPlugins={[remarkGfm]} rehypePlugins={[rehypeHighlight]}>{block.text}</Markdown></div>;
      case "tool": return <ToolCard id={block.call.id} />;
      case "plan": return <PlanCard entries={block.entries} />;
    }
  },
  // Same block object usually means nothing changed; tool updates keep
  // the block but swap `call`, so compare that too.
  (a, b) => {
    if (a.block !== b.block) return false;
    if (a.block.kind === "tool" && b.block.kind === "tool") return a.block.call === b.block.call;
    return true;
  },
);

export function App() {
  useSyncExternalStore(
    (onChange) => store.subscribe(onChange),
    () => store.revision,
  );
  const scroller = useRef<HTMLDivElement>(null);
  const pinned = useRef(true);

  // Render window: the store holds the whole transcript, but only the
  // newest INITIAL_WINDOW blocks mount. Scrolling near the top pages
  // WINDOW_PAGE older blocks in, anchored so the viewport stays put.
  const total = store.blocks.length;
  const [windowCount, setWindowCount] = useState(INITIAL_WINDOW);
  const generation = store.generation;
  useEffect(() => { setWindowCount(INITIAL_WINDOW); }, [generation]);
  const visible = total > windowCount ? store.blocks.slice(-windowCount) : store.blocks;

  const sentinelRef = useRef<HTMLDivElement>(null);
  const growAnchor = useRef<{ height: number; top: number } | null>(null);
  useEffect(() => {
    const el = sentinelRef.current;
    const sc = scroller.current;
    if (!el || !sc) return;
    const obs = new IntersectionObserver((entries) => {
      if (!entries.some((e) => e.isIntersecting)) return;
      if (windowCount >= total) return;
      growAnchor.current = { height: sc.scrollHeight, top: sc.scrollTop };
      setWindowCount((c) => Math.min(c + WINDOW_PAGE, total));
    }, { root: sc, rootMargin: "300px" });
    obs.observe(el);
    return () => obs.disconnect();
  }, [windowCount, total]);

  useLayoutEffect(() => {
    const a = growAnchor.current;
    growAnchor.current = null;
    const sc = scroller.current;
    if (!a || !sc) return;
    sc.scrollTop = a.top + (sc.scrollHeight - a.height);
  });

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
        {visible.length < total && (
          <div className="history-more" ref={sentinelRef}>加载更早消息…</div>
        )}
        {visible.map((block) => <BlockView key={block.id} block={block} />)}
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

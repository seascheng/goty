import React, { useEffect, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import Markdown from "react-markdown";
import remarkGfm from "remark-gfm";
import rehypeHighlight from "rehype-highlight";
import { store, fmtTokens, type Block, type ConfigChoice, type PlanEntry, type ToolCall } from "./store";
import { postToHost } from "./bridge";

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
  const oldText = call.oldText ?? "";
  // The DP is O(n·m) — memo it or every parent re-render (streaming
  // chunks bump the revision constantly) re-runs the whole matrix.
  // newGuaranteed: the early return below never precedes the hooks.
  const newGuaranteed = newText ?? "";
  const rows = useMemo(() => lineDiff(oldText, newGuaranteed),
                       [oldText, newGuaranteed]);
  const adds = useMemo(() => rows.filter((r) => r.type === "add").length, [rows]);
  const dels = useMemo(() => rows.filter((r) => r.type === "del").length, [rows]);
  if (path == null || newText == null) return null;
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

/// Uniform 12×12 stroke glyphs (lucide geometry) — unicode fallbacks
/// rendered at wildly different sizes across kinds.
function ToolGlyph({ kind }: { kind: string }) {
  const common = { width: 12, height: 12, viewBox: "0 0 24 24", fill: "none",
                   stroke: "currentColor", strokeWidth: 2.2,
                   strokeLinecap: "round" as const, strokeLinejoin: "round" as const };
  switch (kind) {
    case "execute":
      return <svg {...common}><polyline points="4 17 10 11 4 5" /><line x1="12" x2="20" y1="19" y2="19" /></svg>;
    case "read":
      return <svg {...common}><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z" /><path d="M14 2v6h6" /></svg>;
    case "edit":
      return <svg {...common}><path d="M17 3a2.85 2.83 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5Z" /></svg>;
    case "search":
      return <svg {...common}><circle cx="11" cy="11" r="7" /><line x1="21" x2="16.5" y1="21" y2="16.5" /></svg>;
    case "agent":
      return <svg {...common}><rect x="5" y="8" width="14" height="12" rx="2" /><path d="M12 8V4" /><circle cx="12" cy="3" r="1" /><circle cx="9" cy="13" r="0.5" /><circle cx="15" cy="13" r="0.5" /></svg>;
    case "fetch":
      return <svg {...common}><circle cx="12" cy="12" r="9" /><path d="M3 12h18" /><path d="M12 3a15 15 0 0 1 0 18 a15 15 0 0 1 0-18" /></svg>;
    default:
      return <svg {...common}><path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z" /></svg>;
  }
}

function ToolCard({ id }: { id: string }) {
  const call = store.tools.get(id)!;
  const isDiff = call.kind != null && editKinds.has(call.kind);
  // Tools stay folded by default (the header carries status + glyph);
  // a card the user opened while running folds on clean completion.
  const [open, setOpen] = useState(false);
  const seenStatus = useRef(call.status);
  if (call.status !== seenStatus.current) {
    const was = seenStatus.current;
    seenStatus.current = call.status;
    if ((was === "in_progress" || was === "pending")
        && call.status === "completed" && !isDiff) {
      setOpen(false);
    }
  }
  const running = call.status === "in_progress" || call.status === "pending";
  const statusLabel = call.status === "completed" ? "完成"
    : call.status === "in_progress" ? "运行中"
    : call.status === "pending" ? "等待"
    : call.status === "error" ? "出错"
    : (call.status ?? "");
  const showDiff = isDiff || (call.rawInput?.content != null);
  const textContent = call.content.filter((c) => c.text).map((c) => c.text).join("\n");
  const kind = call.kind ?? "other";
  return (
    <div className={"tool" + (open ? " open" : "") + (running ? " run" : "")}>
      <button className="tool-head" onClick={() => setOpen(!open)}>
        <span className={"chevron" + (open ? " up" : "")}>▸</span>
        <span className="tool-kind" aria-hidden><ToolGlyph kind={kind} /></span>
        <span className="tool-title">{toolDisplayTitle(call)}</span>
        <span className={"tool-status st-" + (call.status ?? "")}>
          <span className="dot" aria-hidden>●</span> {statusLabel}
        </span>
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

/// Dock plan panel: pinned above the composer (TUI model), phase-
/// grouped, collapsible. Replaces the old inline transcript card —
/// which the 60-block render window could scroll out of view.
function PlanPanel({ entries }: { entries: PlanEntry[] }) {
  const [open, setOpen] = useState(true);
  const done = entries.filter((e) => e.status === "completed").length;
  const phases: { name: string | null; items: PlanEntry[] }[] = [];
  for (const e of entries) {
    const last = phases[phases.length - 1];
    if (last && last.name === (e.priority ?? null)) last.items.push(e);
    else phases.push({ name: e.priority ?? null, items: [e] });
  }
  return (
    <div className={"dock-plan" + (open ? "" : " folded")}>
      <button className="dock-head" onClick={() => setOpen(!open)}
        title={open ? "收起计划面板" : "展开计划面板"}>
        <span className={"chevron" + (open ? " up" : "")}>▸</span>
        <span className="plan-title">计划</span>
        <span className="plan-progress">{done}/{entries.length}</span>
      </button>
      {open && (
        <div className="plan-body">
          {phases.map((phase, i) => (
            <div key={i} className="plan-phase">
              {phase.name && <div className="plan-phase-name">{phase.name}</div>}
              {phase.items.map((e, j) => (
                <div key={j} className={"plan-row " + (e.status ?? "")}>
                  <span className="plan-mark">{e.status === "completed" ? "✓"
                    : e.status === "in_progress" ? "◐" : "○"}</span>
                  <span>{e.content}</span>
                </div>
              ))}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

function fmtElapsed(ms: number): string {
  const s = Math.max(0, Math.floor(ms / 1000));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  return h > 0
    ? `${h}h${String(m).padStart(2, "0")}m`
    : `${m}:${String(sec).padStart(2, "0")}`;
}

/// Background async-job rows — the omp TUI's `bg_2 ⟨bash⟩ … 18m53s`
/// line, elapsed ticking client-side from startTime.
function JobsLine({ jobs }: { jobs: { id: string; kind: string;
  status: string; label: string; startTime?: number | null }[] }) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, []);
  return (
    <div className="dock-jobs">
      {jobs.map((job) => (
        <div key={job.id} className="job-row" title={job.label}>
          <span className="job-glyph">⏳</span>
          <span className="job-id">{job.id}</span>
          <span className="job-kind">⟨{job.kind}⟩</span>
          <span className="job-label">{job.label}</span>
          <span className="job-elapsed">
            {job.startTime ? fmtElapsed(now - job.startTime) : ""}
          </span>
        </div>
      ))}
    </div>
  );
}

/// Subagent roster chips (subagent_lifecycle/progress frames).
function SubagentLine({ rows }: { rows: { id: string; state?: string | null;
  detail?: string | null }[] }) {
  const live = rows.filter((r) =>
    !(r.state ?? "").match(/exit|done|fail|released/i));
  if (live.length === 0) return null;
  return (
    <div className="dock-agents">
      {live.map((r) => (
        <span key={r.id} className="agent-chip"
          title={r.detail ?? r.id}>
          <span className="status-dot working" aria-hidden />
          {r.id}{r.state ? ` · ${r.state}` : ""}
        </span>
      ))}
    </div>
  );
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

/// omp-TUI parity for the tool row: label + PRIMARY ARGUMENT —
/// `Read ~/…/PiSession.swift:145-172`, `Bash cargo test -- …`,
/// `Grep toolDisplayTitle …`. Falls back to kind-only when no args.
function toolArgSummary(raw: Record<string, unknown> | null | undefined): string | null {
  if (!raw) return null;
  const s = (v: unknown) => (typeof v === "string" && v.trim() ? v.trim() : null);
  const path = s(raw.path) ?? s(raw.file_path) ?? s(raw.notebook_path) ?? s(raw.url);
  if (path) {
    // Read ranges render like omp: `:offset-(offset+limit-1)`.
    if (typeof raw.offset === "number") {
      const off = raw.offset;
      const end = typeof raw.limit === "number" ? off + (raw.limit as number) - 1 : off;
      return `${path}:${off}-${end}`;
    }
    return path;
  }
  const cmd = s(raw.command);
  if (cmd) return cmd.split("\n")[0];
  const pat = s(raw.pattern) ?? s(raw.query) ?? s(raw.name)
    ?? s(raw.prompt) ?? s(raw.description);
  if (pat) return pat;
  for (const v of Object.values(raw)) {
    const str = s(v);
    if (str) return str;
  }
  return null;
}

/// What the tool row shows as its title. Agent titles win (omp's "占位"
/// placeholder does not); otherwise derive from kind + rawInput.
function toolDisplayTitle(call: ToolCall): string {
  const kindLabel = call.kind === "read" ? "Read"
    : call.kind === "search" ? "Search"
    : call.kind === "edit" || call.kind === "write" ? "Edit"
    : call.kind === "execute" || call.kind === "bash" ? "Bash"
    : call.kind;
  const arg = toolArgSummary(call.rawInput);
  if (arg) {
    const label = kindLabel ?? call.title ?? "Tool";
    const full = `${label} ${arg}`;
    return full.length > 96 ? full.slice(0, 95) + "…" : full;
  }
  if (call.title && call.title !== "占位") return call.title;
  const path = typeof call.rawInput?.path === "string" ? call.rawInput.path : null;
  const base = path ? path.split("/").pop() : null;
  if (kindLabel) return base ? `${kindLabel} ${base}` : kindLabel;
  if (base) return base;
  return call.id;
}

function ConfigChip({ option, icon, open, onToggle, onPick }: {
  option: { id: string; name: string; currentValue?: string | null;
            options: ConfigChoice[] };
  icon: React.ReactNode;
  open: boolean; onToggle: () => void; onPick: (value: string) => void;
}) {
  const current = option.options.find((o) => o.value === option.currentValue);
  return (
    <div className="chip-wrap" data-pop={option.id}>
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
              {o.source && <span className="chip-source">({o.source})</span>}
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

/// History = one icon pill. Whole surface is the target (svg has
/// pointer-events:none) — the old label+caret variant had click dead
/// zones and stacked popovers with the config knobs.
function HistoryChip({ open, onToggle, onSelect }: {
  open: boolean; onToggle: () => void; onSelect: (sessionId: string) => void;
}) {
  return (
    <div className="chip-wrap" data-pop="history">
      <button className={"icon-chip" + (open ? " open" : "")} title="历史会话"
              aria-label="历史会话" onClick={onToggle}>
        <Icon kind="history" />
      </button>
      {open && (
        <div className="chip-pop">
          {store.sessions.length === 0 && <div className="slash-desc">无会话记录</div>}
          {store.sessions.map((s) => (
            <button key={s.sessionId} className="chip-opt hist"
              onClick={() => onSelect(s.sessionId)}>
              <span className="hist-title">{s.title || histFallback(s)}</span>
              <span className="hist-meta">
                {s.messageCount != null ? `${s.messageCount} 条` : ""}
                {s.updatedAt ? ` · ${histFallback(s)}` : ""}
              </span>
            </button>
          ))}
          <div className="hist-footer">
            <button className="chip-opt hist-act"
              onClick={() => postToHost({ type: "export" })}>
              ⇪ 导出 HTML
            </button>
            <button className="chip-opt hist-act"
              onClick={() => postToHost({ type: "stats" })}>
              Σ 统计
            </button>
            <button className="chip-opt hist-act"
              onClick={() => postToHost({ type: "login" })}>
              ⚿ 登录
            </button>
          </div>
          {store.loginProviders.length > 0 && (
            <div className="hist-providers">
              {store.loginProviders.map((p) => (
                <button key={String(p.id ?? p.providerId ?? p.name)}
                  className="chip-opt hist-act"
                  onClick={() => postToHost({ type: "startLogin",
                    providerId: String(p.id ?? p.providerId ?? p.name) })}>
                  ⚿ 登录 {String(p.name ?? p.id ?? p.providerId)}
                </button>
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  );
}

function Composer({ working, phase }: { working: boolean;
  phase: "thinking" | "executing" | "awaitingPermission" | null }) {
  const [text, setText] = useState("");
  const [openPop, setOpenPop] = useState<string | null>(null);
  const [slashIndex, setSlashIndex] = useState(0);
  const [atIndex, setAtIndex] = useState(0);
  const [dismissed, setDismissed] = useState(false);
  const [hist, setHist] = useState<string[]>([]);
  const histIdx = useRef<number | null>(null);
  const ref = useRef<HTMLTextAreaElement>(null);
  const boxRef = useRef<HTMLDivElement>(null);
  // Retry countdown tick: only live while the agent is backing off.
  const [retryNow, setRetryNow] = useState(Date.now());
  useEffect(() => {
    if (!store.retry) return;
    setRetryNow(Date.now());
    const t = setInterval(() => setRetryNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, [store.retry]);

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
      postToHost({ type: "listFiles" });
    }
  }, [atOpen]);

  // Any mousedown closes the open popover UNLESS it landed inside the
  // popover-owning chip itself (data-pop marks the owner). Clicking a
  // DIFFERENT chip closes the first, then its own click reopens — the
  // old early-return-on-any-chip let two popovers stack (the report:
  // history stayed open). A mousedown outside the composer additionally
  // dismisses the @// popups (typing re-arms them).
  useEffect(() => {
    const onDown = (e: MouseEvent) => {
      const target = e.target as Element;
      const owner = target.closest("[data-pop]");
      if (owner) {
        const id = owner.getAttribute("data-pop");
        setOpenPop((cur) => (id === cur ? cur : null));
        return;
      }
      setOpenPop(null);
      if (boxRef.current == null || !boxRef.current.contains(target)) {
        setDismissed(true);
      }
    };
    document.addEventListener("mousedown", onDown);
    return () => document.removeEventListener("mousedown", onDown);
  }, []);

  /// mode: normal (idle) · steer (interrupt the running turn — the
  /// working-Enter default, omp TUI parity: Enter steers, the
  /// follow-up chord queues) · followUp (queue behind the running
  /// turn — the ⌘⏎ path, omp's app.message.followUp).
  const submit = (mode: "normal" | "steer" | "followUp" = "normal") => {
    const trimmed = text.trim();
    if (!trimmed) return;
    if (working && mode === "normal") mode = "steer";
    postToHost({ type: "send", text: trimmed, mode });
    if (mode === "followUp") {
      // QUEUED, not sent yet: omp holds it until the turn settles (probe
      // 2026-09-01: no user echo at enqueue, only at delivery). Echoing
      // it now would park it mid-stream above text that keeps appending —
      // park it instead; the store flushes it as a user block at
      // turnEnded, so it lands in true processing order at the bottom.
      store.apply({ type: "queueMessage", text: trimmed });
    } else {
      // steer interrupts NOW (echoing immediately is the true order);
      // idle sends render optimistically until omp's suppressed echo.
      store.apply({ type: "userMessage", text: trimmed });
    }
    setHist((h) => (h[h.length - 1] === trimmed ? h : [...h, trimmed]));
    histIdx.current = null;
    setText("");
  };

  // Auto-fit height on EVERY text change — programmatic ones included
  // (submit, Escape, ↑/↓ history recall, @-file insert). The old
  // onChange-only sizing left a stale grown height on the cleared box:
  // dead space above the toolbar until the next keystroke.
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    el.style.height = "auto";
    el.style.height = Math.min(el.scrollHeight, 160) + "px";
  }, [text]);

  const pickSlash = (name: string) => {
    setText("/" + name + " ");
    ref.current?.focus();
  };

  const pickAt = (file: string) => {
    setText(text.replace(/@([\w./-]*)$/, "@" + file + " "));
    ref.current?.focus();
  };


  const pickConfig = (configId: string, value: string) => {
    postToHost({ type: "setConfig", configId, value });
    setOpenPop(null);
  };


  const onComposerKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    // IME composition (中文输入法候选框): the Enter that CONFIRMS the
    // composition must not send. WKWebView reports isComposing on those
    // keydowns (and keyCode 229 on some IMEs) — bail before any
    // Enter/arrow handling.
    if (e.nativeEvent.isComposing || e.keyCode === 229) return;
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
      if (openPop != null) { setOpenPop(null); return; }
    }
    if (e.key === "Escape" && working && !slashOpen && atMatches.length === 0) {
      e.preventDefault();
      postToHost({ type: "stop" });
      return;
    }
    if (slashOpen) {
      if (e.key === "ArrowDown") { e.preventDefault(); setSlashIndex((i) => (i + 1) % slashMatches.length); return; }
      if (e.key === "ArrowUp") { e.preventDefault(); setSlashIndex((i) => (i - 1 + slashMatches.length) % slashMatches.length); return; }
      if (e.key === "Enter" || e.key === "Tab") {
        e.preventDefault(); pickSlash(slashMatches[slashIndex].name); return;
      }
    }
    if (e.key === "Enter" && e.metaKey && !e.shiftKey) {
      // ⌘⏎ queues behind the running turn (omp TUI's Ctrl+Enter /
      // app.message.followUp chord); idle it just sends.
      e.preventDefault();
      submit(working ? "followUp" : "normal");
      return;
    }
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      // While working, plain Enter STEERS — interrupt the run and
      // inject (omp TUI parity; the queue rides ⌘⏎). Never a silent
      // no-op.
      submit();
    }
  };

  return (
    <div className="composer">
      <div className="composer-box" ref={boxRef}>
        {(store.reconnecting || store.starting || store.error != null || store.retry != null) && (
        <div className="composer-status">
          {store.reconnecting && (
            <span className="cstat warn" title="连接断开，正在自动重连；远端进程仍在运行">
              <span className="spin" />重连中…
            </span>
          )}
          {store.starting && !store.reconnecting && (
            <span className="cstat" title="agent 进程已启动，握手完成前模型/思考等控件不可用">
              <span className="spin" />正在启动 {store.starting}…
            </span>
          )}
          {store.error != null && (
            <span className="cstat error" title={store.error}>
              {store.error}
              <button className="chip-retry"
                onClick={() => postToHost({ type: "reconnect" })}>重试</button>
            </span>
          )}
          {store.retry && (
            <span className="cstat retry" title={store.retry.errorText
              ? `模型限流，自动重试中\n\n${store.retry.errorText}`
              : "模型限流，自动重试中；可稍后手动重发"}>
              <span className="spin" />重试中 {store.retry.attempt}/{store.retry.maxAttempts} · {Math.max(0, Math.ceil((store.retry.endsAt - retryNow) / 1000))}s
            </span>
          )}
        </div>
        )}
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
          {store.sessionTitle && (
            <span className="pane-session-title" title={store.sessionTitle}>
              {store.sessionTitle}
            </span>
          )}
          <HistoryChip open={openPop === "history"}
            onToggle={() => {
              const next = openPop !== "history";
              setOpenPop(next ? "history" : null);
              if (next) postToHost({ type: "listSessions" });
            }}
            onSelect={(sessionId) => {
              postToHost({ type: "loadSession", sessionId });
              store.apply({ type: "clearTranscript" });
              setOpenPop(null);
            }} />
          {store.runtime?.fastEnabled != null && (
            <button
              className={"icon-chip fast" + (store.runtime.fastActive ? " on" : "")}
              title={store.runtime.fastActive
                ? "fast 模式激活中 — 点击关闭"
                : "开启 fast 模式（优先吞吐档位）"}
              onClick={() => postToHost({ type: "setFast", enabled: !store.runtime?.fastEnabled })}>
              ⚡
            </button>
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
          </div>
        <div className="toolbar-right">
          {store.meta?.directory && (
            <span className="pane-meta" title={[store.meta.workspace, store.meta.directory]
              .filter(Boolean).join("/") + (store.meta.branch ? ` · ${store.meta.branch}` : "")}>
              {[store.meta.workspace, store.meta.directory].filter(Boolean).join("/")}
            </span>
          )}
          {(() => {
            const u = store.usage;
            const rt = store.runtime;
            const parts: string[] = [];
            if (u?.input != null) parts.push(`↑${fmtTokens(u.input)}`);
            if (u?.output != null) parts.push(`↓${fmtTokens(u.output)}`);
            if (u?.used != null && u?.size != null && u.size > 0) {
                parts.push(`${((u.used / u.size) * 100).toFixed(1)}%/${fmtTokens(u.size)}`);
            } else if (u?.used != null) {
                parts.push(`↑${fmtTokens(u.used)}`);
            }
            const ctxPct = (rt?.contextTokens != null && rt?.contextWindow != null
                && rt.contextWindow > 0)
                ? (rt.contextTokens / rt.contextWindow) * 100 : null;
            if (ctxPct != null) {
                parts.push(`◧ ctx ${ctxPct.toFixed(1)}%`);
            } else if (rt?.contextTokens != null) {
                parts.push(`◧ ${fmtTokens(rt.contextTokens)}`);
            }
            if (parts.length === 0) return null;
            // omp's own gauge thresholds (context-thresholds.ts): warning
            // ≥50% or 150k tokens, purple ≥70%/270k, error ≥90%/500k —
            // whichever bound (percent vs tokens-per-window) hits first.
            const level = ctxPct == null ? "normal"
                : ctxPct >= Math.min(90, (500_000 / (rt!.contextWindow || 1)) * 100) ? "error"
                : ctxPct >= Math.min(70, (270_000 / (rt!.contextWindow || 1)) * 100) ? "purple"
                : ctxPct >= Math.min(50, (150_000 / (rt!.contextWindow || 1)) * 100) ? "warning"
                : "normal";
            return <span className={`usage ctx-${level}`}>{parts.join(" · ")}</span>;
          })()}

          {(Math.max(store.runtime?.queued ?? 0, store.pendingQueue.length) > 0) && (
            <span className="queue-badge" title="排队中的消息（turn 结束后依次处理）">
              ⇥ 排队 {Math.max(store.runtime?.queued ?? 0, store.pendingQueue.length)}
            </span>
          )}
          {working && (
            <button className="action-btn queue" disabled={!text.trim()}
              title="排队发送 (⌘⏎) — 当前 turn 结束后依次处理"
              onClick={() => submit("followUp")}>
              ⇥
            </button>
          )}
          <button
            className={"action-btn " + (working ? "stop" : "send")
              + (phase === "awaitingPermission" ? " awaiting" : "")}
            disabled={working ? false : !text.trim()}
            title={working ? "插话发送 (Enter，中断当前 turn) / 停止 (空文本或 Esc)" : "发送 (Enter)"}
            onClick={() => working
              ? (text.trim() ? submit("steer")
                : postToHost({ type: "stop" }))
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
/// Upper bound on mounted blocks. The window GROWS while the user reads
/// above a live stream (start is top-anchored, appends never unmount);
/// returning to the bottom trims back to this.
const MAX_WINDOW = INITIAL_WINDOW + WINDOW_PAGE;

/// Branch affordance. The fork runs in a throwaway process server-side
/// (worktree semantics) — it is safe while a turn streams, so the only
/// gate is the entry id itself (stamped by store replay).
const BranchButton = React.memo(
  function BranchButton({ entryId, label, className }: {
    entryId: string | null; label: string; className?: string }) {
    // Shared pane-level busy flag: the fork is a pure file operation
    // (~10ms) with a process fallback; EVERY branch button shows
    // 分支中… and refuses clicks until it lands, so rapid clicks
    // cannot spawn N tabs.
    const busy = useSyncExternalStore(
      (onChange) => store.subscribe(onChange),
      () => store.branchBusy,
      () => false,
    );
    const disabled = !entryId || busy;
    const title = !entryId
      ? "该消息还没有会话条目 id（重开窗格或加载历史后可从此处分支）"
      : busy ? "分支创建中……"
      : "从此处分叉到新标签页继续（原会话与原窗口保留不动；turn 进行中同样可用）";
    return (
      <button
        className={(className ?? "branch-btn") + (disabled ? " dim" : "")}
        disabled={disabled} title={title}
        onClick={() => {
          if (!entryId || busy) return;
          postToHost({ type: "branchNewPane", entryId });
        }}>{busy ? "⎿ 分支中…" : label}</button>
    );
  });

/// One transcript row. Memoized: during replay only the newest blocks
/// change identity, so scroll-up pagination re-renders just the newly
/// revealed rows and streaming re-renders only the tail block.
const BlockView = React.memo(
  function BlockView({ block, showBranch = false }:
      { block: Block; showBranch?: boolean }) {
    switch (block.kind) {
      case "user": return (
        <div className="user-row">
          <div className="user">{block.text}</div>
        </div>
      );
      case "agent": return block.text ? (
        <div className="agent">
          <Markdown remarkPlugins={[remarkGfm]}
            rehypePlugins={[rehypeHighlight]}>{block.text}</Markdown>
          {showBranch && block.entryId ? (
            <BranchButton entryId={block.entryId} label="⎿ 分支到新标签页"
              className="branch-btn agent-branch" />
          ) : null}
        </div>) : null;
      case "thought": return <div className="thought"><Markdown remarkPlugins={[remarkGfm]} rehypePlugins={[rehypeHighlight]}>{block.text}</Markdown></div>;
      case "tool": return <ToolCard id={block.call.id} />;
      case "turnStats": return <div className="turn-stats">{block.text}</div>;
      case "error": return <div className="block-error">Error: {block.text}</div>;
      case "notice": return <div className="block-notice">{block.text}</div>;
    }
  },
  // Same block object usually means nothing changed; tool updates keep
  // the block but swap `call`, so compare that too. showBranch is
  // positional (last content block of a turn) and flips as blocks
  // append — compare it too or the button sticks to the wrong block.
  (a, b) => {
    if (a.block !== b.block) return false;
    if (a.showBranch !== b.showBranch) return false;
    if (a.block.kind === "tool" && b.block.kind === "tool") return a.block.call === b.block.call;
    return true;
  },
);

/// Turn status lives at the TAIL of the transcript (orca statusbar
/// model): live phase chips while the model works, then the turn's
/// duration (+token usage when the agent reports it) once it settles.
function StatusLine() {
  const s = store;
  const rt = store.runtime;
  const chips: React.ReactNode[] = [];
  // /compact runs as a normal model turn, so phase=thinking holds —
  // the compacting chip is the sharper truth; don't spin both.
  if (s.phase === "thinking" && !rt?.compacting) {
    chips.push(<span key="th" className="cstat" title="模型思考中"><span className="spin" />思考中…</span>);
  } else if (s.phase === "executing") {
    // Live tool telemetry: name the tool actually running (claude TUI
    // parity — a bare 执行中 hides which of the turn's tools is active).
    let running: ToolCall | null = null;
    for (let i = s.toolOrder.length - 1; i >= 0; i--) {
      const t = s.tools.get(s.toolOrder[i]);
      if (t && (t.status === "in_progress" || t.status === "pending")) { running = t; break; }
    }
    chips.push(
      <span key="ex" className="cstat" title="工具执行中">
        <span className="spin" />执行中{running ? ` · ${toolDisplayTitle(running)}` : ""}…
      </span>);
  } else if (s.phase === "awaitingPermission") {
    chips.push(<span key="ap" className="cstat awaiting" title="等待你在下方授权">等待授权</span>);
  }
  // (Settled-turn duration lives INSIDE the transcript now — a
  // turnStats block glued to the turn it closes, so the next user
  // message appends below it instead of above the composer.)
  if (rt?.tokensPerSecond != null && rt.tokensPerSecond > 0) {
    chips.push(<span key="tps" className="cstat" title="输出吞吐">{rt.tokensPerSecond.toFixed(1)} tok/s</span>);
  }
  if (rt?.compacting) {
    chips.push(<span key="compact" className="cstat warn" title="上下文压缩中"><span className="spin" />压缩中…</span>);
  }
  if (chips.length === 0) return null;
  return <div className="composer-status">{chips}</div>;
}

export function App() {
  useSyncExternalStore(
    (onChange) => store.subscribe(onChange),
    () => store.revision,
  );
  const scroller = useRef<HTMLDivElement>(null);
  const [atBottom, setAtBottom] = useState(true);

  // ——— scroll controller: happier's userScrollIntentOwner, distilled ———
  // THREE invariants (their viewport subsystem, battle-tested):
  //  1. ONE writer: the only automatic scroll is follow-to-bottom, and
  //     only when (not parked) AND (no live user gesture). Multiple
  //     writers chasing the bottom is exactly the captured "oscillating
  //     bottom" jitter (their 2026-07-22 note — and our 2026-09-01 one).
  //  2. Intent window: raw input (wheel/touch/scroll-keys) OR momentum
  //     frames within 320ms = the reader's hand is on the scroller —
  //     hands off. Momentum continuation emits scroll events, so
  //     user-caused scroll events also refresh the timestamp.
  //  3. Parking is MEASURED, not directional: >24px from the bottom
  //     under the user's hand parks; reaching the tail (or the ↓
  //     button) releases. Programmatic writes self-identify (100ms
  //     echo window) so their own scroll events can't masquerade as
  //     user intent.
  const PIN_THRESHOLD_PX = 24;
  const INTENT_WINDOW_MS = 320;
  const parked = useRef(false);
  const lastRawInputAt = useRef(-Infinity);
  const lastWriteAt = useRef(0);
  const growing = useRef(false);

  useEffect(() => {
    const el = scroller.current;
    if (!el) return;
    const record = () => { lastRawInputAt.current = performance.now(); };
    const onKey = (e: KeyboardEvent) => {
      if (["PageUp", "PageDown", "Home", "End", "ArrowUp", "ArrowDown", " "].includes(e.key)) record();
    };
    el.addEventListener("wheel", record, { passive: true });
    el.addEventListener("touchmove", record, { passive: true });
    el.addEventListener("keydown", onKey);
    return () => {
      el.removeEventListener("wheel", record);
      el.removeEventListener("touchmove", record);
      el.removeEventListener("keydown", onKey);
    };
  }, []);


  // Esc ANYWHERE in the pane stops a working agent — not only while
  // the composer is focused (its own handler covers that case).
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      if ((e.target as HTMLElement | null)?.tagName === "TEXTAREA") return;
      if (!store.working) return;
      e.preventDefault();
      postToHost({ type: "stop" });
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, []);

  // Render window: the store holds the whole transcript, but only the
  // blocks from `start` on mount. `start` is TOP-anchored: streaming
  // appends mount BELOW it and never unmount what the user is reading
  // (a tail-anchored window slid on every new block — each slide
  // unmounted the top block and the viewport jumped with it once the
  // transcript passed the window). Scrolling near the top pages
  // WINDOW_PAGE older blocks in, anchored so the viewport stays put.
  const total = store.blocks.length;
  const [start, setStart] = useState(() => Math.max(0, total - INITIAL_WINDOW));
  const generation = store.generation;
  useEffect(() => { setStart(Math.max(0, store.blocks.length - INITIAL_WINDOW)); }, [generation]);
  // A shrunk transcript (transcriptReset) can leave start past the tail:
  // fall back to the tail window instead of rendering nothing.
  const begin = Math.min(start, Math.max(0, total - INITIAL_WINDOW));
  const visible = store.blocks.slice(begin);

  const sentinelRef = useRef<HTMLDivElement>(null);
  const growAnchor = useRef<{ height: number; top: number } | null>(null);
  const olderInFlight = useRef(false);

  // Prepend consumption: blocks arrived in FRONT (ids shifted by
  // delta). Measure the anchor BEFORE commit (the render body runs
  // against the old DOM), shift the window by the same delta so the
  // mounted slice is unchanged, and let the layout effect restore the
  // viewport over the newly inserted height above.
  if (store.prependDelta > 0) {
    const sc = scroller.current;
    if (sc) growAnchor.current = { height: sc.scrollHeight, top: sc.scrollTop };
    growing.current = true;
    const delta = store.prependDelta;
    store.prependDelta = 0;
    setStart((s) => s + delta);
  }
  // Every prepend arrival (empty or not) releases the sentinel's
  // single-flight guard.
  const prependEpoch = store.prependEpoch;
  useEffect(() => { olderInFlight.current = false; }, [prependEpoch]);

  useEffect(() => {
    const el = sentinelRef.current;
    const sc = scroller.current;
    if (!el || !sc) return;
    const obs = new IntersectionObserver((entries) => {
      if (!entries.some((e) => e.isIntersecting)) return;
      if (growing.current) return;
      if (begin > 0) {
        // Window growth (blocks already held): mount one page more.
        growing.current = true;
        growAnchor.current = { height: sc.scrollHeight, top: sc.scrollTop };
        setStart((s) => Math.max(0, s - WINDOW_PAGE));
      } else if (store.hasOlder && !olderInFlight.current) {
        // Top of the HELD history but older exists server-side
        // (tail-first load): page it in — single flight, happier's
        // loadOlder discipline.
        olderInFlight.current = true;
        postToHost({ type: "loadOlder" });
      }
    }, { root: sc, rootMargin: "0px" });
    obs.observe(el);
    return () => obs.disconnect();
  }, [begin, total]);

  useLayoutEffect(() => {
    const a = growAnchor.current;
    if (!a) return;
    growAnchor.current = null;
    const sc = scroller.current;
    if (!sc) return;
    // Prepend compensation, then ONE rAF correction pass: async layout
    // (syntax highlighting, fonts) keeps shifting scrollHeight after
    // paint, and an uncompensated drift re-trips the sentinel during
    // momentum — the "flew to the top" report (2026-09-01).
    sc.scrollTop = a.top + (sc.scrollHeight - a.height);
    const settledHeight = sc.scrollHeight;
    requestAnimationFrame(() => {
      const drift = sc.scrollHeight - settledHeight;
      if (drift !== 0) sc.scrollTop += drift;
      growing.current = false;
    });
  });
  useEffect(() => {
    const el = scroller.current;
    if (!el || parked.current) return;
    if (performance.now() - lastRawInputAt.current < INTENT_WINDOW_MS) return;
    const target = el.scrollHeight;
    if (Math.abs(target - el.clientHeight - el.scrollTop) < 0.5) return;
    lastWriteAt.current = performance.now();
    el.scrollTop = target;
  });

  const onScroll = () => {
    const el = scroller.current!;
    const now = performance.now();
    const distance = Math.max(0, el.scrollHeight - el.clientHeight - el.scrollTop);
    const byUser = now - lastWriteAt.current > 100;
    if (byUser) {
      // User-caused movement (raw input or its momentum frames):
      // refresh intent (invariant 2) and settle parking by MEASUREMENT
      // (invariant 3).
      lastRawInputAt.current = now;
      parked.current = distance > PIN_THRESHOLD_PX;
    } else if (distance <= PIN_THRESHOLD_PX) {
      // Our own write's echo landing on the tail.
      parked.current = false;
    }
    setAtBottom(distance <= PIN_THRESHOLD_PX);
    // Bound the window: it grows while the user reads above a live
    // stream. Trim once they're back at the tail — unmounting ABOVE
    // the viewport cannot move what the user sees.
    if (!parked.current && total - begin > MAX_WINDOW) {
      setStart(Math.max(0, total - MAX_WINDOW));
    }
  };

  const jumpToBottom = () => {
    // Explicit command: release parking AND revoke input evidence (the
    // user just told us they want the tail — stale intent must not
    // block the landing).
    parked.current = false;
    lastRawInputAt.current = -Infinity;
    const sc = scroller.current;
    if (sc) {
      lastWriteAt.current = performance.now();
      sc.scrollTop = sc.scrollHeight;
    }
    setAtBottom(true);
  };

  return (
    <div className="pane">
      <div className="transcript" ref={scroller} onScroll={onScroll}>
        {(begin > 0 || store.hasOlder) && (
          <div className="history-more" ref={sentinelRef}>加载更早消息…</div>
        )}
        {visible.map((block, i) => (
          <BlockView key={block.id} block={block}
            // The branch affordance belongs at the END of a turn's LLM
            // output, not on every entryId-stamped fragment before it
            // (thought/tool interleaving splits one message into many
            // agent blocks). Last content block of the turn only.
            showBranch={block.kind === "agent" && block.entryId != null
              && (i + 1 >= visible.length
                  || (visible[i + 1].kind !== "agent"
                      && visible[i + 1].kind !== "thought"
                      && visible[i + 1].kind !== "tool"))} />
        ))}
        <StatusLine />
      </div>
      {!atBottom && (
        <button className="jump-bottom" title="回到底部（跟随最新输出）"
          onClick={jumpToBottom}>↓</button>
      )}
      {(store.plan || store.jobs.length > 0 || store.subagents.length > 0
        || store.pendingQueue.length > 0) && (
        <div className="dock">
          {store.plan && <PlanPanel entries={store.plan.entries} />}
          {store.jobs.length > 0 && <JobsLine jobs={store.jobs} />}
          <SubagentLine rows={store.subagents} />
          {store.pendingQueue.length > 0 && (
            <div className="dock-outbox" title="排队中的消息：turn 结束后按序送达">
              {store.pendingQueue.map((text, i) => (
                <div className="outbox-row" key={i}>
                  <span className="outbox-mark">⇥</span>
                  <span className="outbox-text">{text}</span>
                </div>
              ))}
            </div>
          )}
        </div>
      )}
      {store.permission && <PermissionCard permission={store.permission} />}
      <Composer working={store.working} phase={store.phase} />
      {store.stats && <StatsDialog stats={store.stats} />}
    </div>
  );
}

/// The agent asked a question / needs approval — RPC extension dialogs
/// ride the same card: option lists (select/approvals), 确认/取消
/// (confirm), or a text entry (input/editor).
function PermissionCard({ permission }: {
  permission: NonNullable<typeof store.permission>;
}) {
  const [value, setValue] = useState(permission.defaultValue ?? "");
  const isInput = permission.dialog === "input" || permission.dialog === "editor";
  return (
    <div className="permission">
      <div className="perm-title">{permission.toolCallTitle ?? "需要授权"}</div>
      {isInput ? (
        <div className="perm-input">
          <input autoFocus value={value}
            placeholder={permission.placeholder ?? ""}
            onChange={(e) => setValue(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && value.trim()) {
                postToHost({ type: "permission", optionId: value });
              }
            }} />
          <button className="btn send" disabled={!value.trim()}
            onClick={() => postToHost({ type: "permission", optionId: value })}>提交</button>
        </div>
      ) : (
        <div className="perm-options">
          {permission.options.map((o) => (
            <button key={o.optionId}
              className={"btn " + (o.kind?.startsWith("allow") ? "send" : "")}
              onClick={() => postToHost({ type: "permission", optionId: o.optionId })}>
              {o.name}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

/// get_session_stats overlay: raw key/value table, click-outside closes.
function StatsDialog({ stats }: { stats: Record<string, unknown> }) {
  return (
    <div className="stats-overlay" onClick={() => store.closeStats()}>
      <div className="stats-card" onClick={(e) => e.stopPropagation()}>
        <div className="stats-head">
          <span>会话统计</span>
          <button className="chip-retry" onClick={() => store.closeStats()}>关闭</button>
        </div>
        <table className="stats-table">
          <tbody>
            {Object.entries(stats).map(([k, v]) => (
              <tr key={k}><td>{k}</td><td>{typeof v === "object" ? JSON.stringify(v) : String(v)}</td></tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

import React, { useEffect, useRef, useState, useSyncExternalStore } from "react";
import Markdown from "react-markdown";
import remarkGfm from "remark-gfm";
import rehypeHighlight from "rehype-highlight";
import { store } from "./store";

function ToolCard({ id }: { id: string }) {
  const call = store.tools.get(id)!;
  const [open, setOpen] = useState(call.status === "in_progress");
  const running = call.status === "in_progress" || call.status === "pending";
  const statusLabel = call.status === "completed" ? "完成"
    : call.status === "in_progress" ? "运行中"
    : call.status === "pending" ? "等待"
    : (call.status ?? "");
  return (
    <div className={"tool" + (open ? " open" : "")}>
      <button className="tool-head" onClick={() => setOpen(!open)}>
        <span className={"chevron" + (open ? " up" : "")}>▸</span>
        <span className="tool-title">{call.title ?? call.id}</span>
        <span className={"tool-status" + (running ? " running" : "")}>{statusLabel}</span>
      </button>
      {open && (
        <div className="tool-body">
          {call.content.map((c, j) => c.text
            ? <pre key={j}><code>{c.text}</code></pre>
            : c.path ? <div key={j} className="tool-path">{c.path}</div> : null)}
        </div>
      )}
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
function ConfigChip({ option, open, onToggle, onPick }: {
  option: { id: string; name: string; currentValue?: string | null;
            options: { value: string; name: string }[] };
  open: boolean; onToggle: () => void; onPick: (value: string) => void;
}) {
  const current = option.options.find((o) => o.value === option.currentValue);
  return (
    <div className="chip-wrap">
      <button className={"chip" + (open ? " open" : "")} onClick={onToggle}>
        <span className="chip-name">{option.name}</span>
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

function Composer({ working }: { working: boolean }) {
  const [text, setText] = useState("");
  const [openChip, setOpenChip] = useState<string | null>(null);
  const [slashIndex, setSlashIndex] = useState(0);
  const ref = useRef<HTMLTextAreaElement>(null);

  const slashQuery = /^\/[\w-]*$/.test(text) ? text.slice(1).toLowerCase() : null;
  const slashMatches = slashQuery == null ? [] :
    store.commands.filter((c) => c.name.toLowerCase().startsWith(slashQuery));
  const slashOpen = slashQuery != null && slashMatches.length > 0;

  const submit = () => {
    const trimmed = text.trim();
    if (!trimmed || working) return;
    window.webkit?.messageHandlers.goty.postMessage({ type: "send", text: trimmed });
    store.apply({ type: "userMessage", text: trimmed });
    setText("");
    ref.current?.style.setProperty("height", "auto");
  };

  const pickSlash = (name: string) => {
    setText("/" + name + " ");
    ref.current?.focus();
  };

  const pickConfig = (configId: string, value: string) => {
    window.webkit?.messageHandlers.goty.postMessage({ type: "setConfig", configId, value });
    setOpenChip(null);
  };

  return (
    <div className="composer">
      <div className="composer-box">
        <textarea
          ref={ref}
          value={text}
          rows={1}
          placeholder="Message the agent…  (Enter 发送，Shift+Enter 换行，/ 指令)"
          onChange={(e) => {
            setText(e.target.value);
            setSlashIndex(0);
            const el = e.target;
            el.style.height = "auto";
            el.style.height = Math.min(el.scrollHeight, 140) + "px";
          }}
          onKeyDown={(e) => {
            if (e.nativeEvent.isComposing) return;
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
          }}
        />
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
      <div className="composer-bar">
        <div className="statusbar-left">
          {store.configOptions.map((option) => (
            <ConfigChip key={option.id} option={option}
              open={openChip === option.id}
              onToggle={() => setOpenChip(openChip === option.id ? null : option.id)}
              onPick={(value) => pickConfig(option.id, value)} />
          ))}
        </div>
        <div className="statusbar-right">
          {store.usage && (store.usage.used != null || store.usage.costAmount != null) && (
            <span className="usage">
              {store.usage.used != null && <>↑{fmtTokens(store.usage.used)}</>}
              {store.usage.size != null && <> / {fmtTokens(store.usage.size)}</>}
              {store.usage.costAmount != null && <> · ${store.usage.costAmount.toFixed(4)}</>}
            </span>
          )}
          <span className={"status-dot " + (working ? "working" : "")} />
          <span className="status-text">{working ? "运行中…" : store.status}</span>
          {working && (
            <button className="btn stop" onClick={() =>
              window.webkit?.messageHandlers.goty.postMessage({ type: "stop" })}>
              停止
            </button>
          )}
          <button className="btn send" disabled={!text.trim() || working} onClick={submit}>
            发送
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
    <div className="pane" onClick={() => { /* click-away closes chips via capture below */ }}>
      <div className="transcript" ref={scroller} onScroll={onScroll}>
        {store.blocks.map((block, i) => {
          switch (block.kind) {
            case "user": return <div key={i} className="user-row"><div className="user">{block.text}</div></div>;
            case "agent": return block.text ? (
              <div key={i} className="agent"><Markdown remarkPlugins={[remarkGfm]}
                rehypePlugins={[rehypeHighlight]}>{block.text}</Markdown></div>) : null;
            case "thought": return <div key={i} className="thought">{block.text}</div>;
            case "tool": return <ToolCard key={i} id={block.call.id} />;
            case "plan": return (
              <div key={i} className="plan">
                {block.entries.map((e, j) => (
                  <div key={j} className={"plan-row " + (e.status ?? "")}>
                    <span className="plan-mark">{e.status === "completed" ? "✓" : e.status === "in_progress" ? "◐" : "○"}</span>
                    <span>{e.content}</span>
                  </div>
                ))}
              </div>
            );
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

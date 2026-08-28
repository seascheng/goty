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
        <span className="tool-icon">{call.kind === "read" ? "📄" : call.kind === "edit" || call.kind === "write" ? "✏️" : call.kind === "bash" ? "❯" : "🔧"}</span>
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

function Composer({ working }: { working: boolean }) {
  const [text, setText] = useState("");
  const ref = useRef<HTMLTextAreaElement>(null);

  const submit = () => {
    const trimmed = text.trim();
    if (!trimmed || working) return;
    window.webkit?.messageHandlers.goty.postMessage({ type: "send", text: trimmed });
    store.apply({ type: "userMessage", text: trimmed });
    setText("");
  };

  return (
    <div className="composer">
      <div className="composer-box">
        <textarea
          ref={ref}
          value={text}
          rows={1}
          placeholder="Message the agent…  (Enter 发送，Shift+Enter 换行)"
          onChange={(e) => {
            setText(e.target.value);
            const el = e.target;
            el.style.height = "auto";
            el.style.height = Math.min(el.scrollHeight, 140) + "px";
          }}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) {
              e.preventDefault();
              submit();
            }
          }}
        />
      </div>
      <div className="composer-bar">
        <span className={"status-dot " + (working ? "working" : "")} />
        <span className="status-text">{working ? "运行中…" : store.status}</span>
        <div className="composer-actions">
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

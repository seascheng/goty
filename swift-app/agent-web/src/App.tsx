import React, { useEffect, useRef, useSyncExternalStore } from "react";
import Markdown from "react-markdown";
import remarkGfm from "remark-gfm";
import rehypeHighlight from "rehype-highlight";
import { store } from "./store";

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
    <div className="transcript" ref={scroller} onScroll={onScroll}>
      {store.blocks.map((block, i) => {
        switch (block.kind) {
          case "user": return <div key={i} className="user">{block.text}</div>;
          case "agent": return block.text ? (
            <div key={i} className="agent"><Markdown remarkPlugins={[remarkGfm]}
              rehypePlugins={[rehypeHighlight]}>{block.text}</Markdown></div>) : null;
          case "thought": return <div key={i} className="thought">{block.text}</div>;
          case "tool": {
            const call = store.tools.get(block.call.id)!;
            return (
              <details key={i} className={"tool " + (call.status ?? "")} open={call.status === "in_progress"}>
                <summary>{call.title ?? call.id}<span className="status">{call.status}</span></summary>
                {call.content.map((c, j) => c.text ? <pre key={j}><code>{c.text}</code></pre>
                  : c.path ? <div key={j} className="path">{c.path}</div> : null)}
              </details>
            );
          }
          case "plan": return (
            <ul key={i} className="plan">
              {block.entries.map((e, j) => (
                <li key={j} className={e.status ?? ""}>{e.content}</li>))}
            </ul>
          );
        }
      })}
      {store.permission && (
        <div className="permission">
          <div className="title">{store.permission.toolCallTitle ?? "需要授权"}</div>
          <div className="options">
            {store.permission.options.map((o) => (
              <button key={o.optionId}
                onClick={() => window.webkit?.messageHandlers.goty.postMessage(
                  { type: "permission", optionId: o.optionId })}>
                {o.name}
              </button>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}

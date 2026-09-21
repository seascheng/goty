import React, { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { Streamdown } from "streamdown";
import { store } from "../store";
import { streamdownProps } from "./CodeBlock";
import { Chevron, Icon } from "./Icon";
import { fmtElapsed } from "./Loader";

/// Thinking renders as a collapsible dim card (happier timeline row):
/// OPEN while the model is actively thinking, folded once the turn
/// moves on — the reasoning stays one click away, not sprawled between
/// the answer's paragraphs.
/// Thinking streams are chatty: models emit double-blank-line breaks
/// between every volley AND bare list markers ("-", "*") with no
/// content — markdown renders those as empty <li> rows while UA-default
/// list margins (1em + 40px indent, no tailwind loaded to tame them)
/// blow every marker into an airy paragraph. Drop marker-only lines,
/// collapse blank runs, trim the edges — the card reads as a compact
/// reasoning trace, not a blog post.
function compactThought(text: string): string {
  // Reasoning often carries literal "\n" escapes AS TEXT (the model
  // wrote them inside code-ish thinking — the stream replays them
  // verbatim): un-escape first, or the card shows "\n\n" walls with no
  // line breaks at all. Display-only layer; the answer's faithful
  // contract is untouched.
  const unescaped = text.replace(/\\r\\n?/g, "\n").replace(/\\n/g, "\n").replace(/\\t/g, " ");
  return unescaped
    .split("\n")
    .filter((line) => !/^\s*[-*•]\s*$/.test(line) && !/^\s*\d+[.)]\s*$/.test(line))
    .join("\n")
    .replace(/[ \t]+$/gm, "")
    .replace(/\n{3,}/g, "\n\n")
    .replace(/^\n+|\n+$/g, "");
}

export function ThoughtView({ text, isTail }: { text: string; isTail: boolean }) {
  // Liveness is POSITIONAL, not global: the model streams sequentially,
  // so only the LAST transcript block can still be thinking — every
  // earlier thought card is already settled history (the 2026-09-02
  // report: all cards pulsed "思考中…" in lockstep). The phase itself is
  const thinking = useSyncExternalStore(
    (onChange) => store.subscribe(onChange),
    () => store.working && store.phase === "thinking",
    () => false,
  );
  const live = isTail && thinking;
  // Same turn clock as StatusLine, scoped to the live card: 思考中 · 12s
  // in the header. Base is the turn start (multi-block turns keep one
  // clock); mount time is the fallback for mid-stream adoption.
  const baseRef = useRef(0);
  if (live && baseRef.current === 0) baseRef.current = store.turnStartedAt ?? Date.now();
  if (!live) baseRef.current = 0;
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    if (!live) return;
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, [live]);
  const liveElapsed = live && baseRef.current > 0 ? now - baseRef.current : null;
  const [open, setOpen] = useState(live);
  return (
    <div className={"thought-card" + (open ? " open" : "") + (live ? " live" : "")}>
      <button className="thought-head" onClick={() => setOpen(!open)}>
        {/* beautifului #02 thinking: the sparkle icon leads the card
            (a bare dot read as nothing); pulses violet while live. */}
        <span className={"thought-glyph" + (live ? " live" : "")} aria-hidden>
          <Icon kind="thinking" />
        </span>
        <span className="thought-label">
          {live
            ? `思考中${liveElapsed != null ? ` · ${fmtElapsed(liveElapsed)}` : ""}…`
            : "思考过程"}
        </span>
        <Chevron open={open} />
      </button>
      {open && (
        <div className="thought agent-reasoning agent-markdown">
          <Streamdown {...streamdownProps}>{compactThought(text)}</Streamdown>
        </div>
      )}
    </div>
  );
}

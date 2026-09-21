import React, { useMemo, useState } from "react";
import rehypeHighlight from "rehype-highlight";

function codeTextOf(node: React.ReactNode): string {
  if (node == null || typeof node === "boolean") return "";
  if (typeof node === "string" || typeof node === "number") return String(node);
  if (Array.isArray(node)) return node.map(codeTextOf).join("");
  if (typeof node === "object" && "props" in node) {
    return codeTextOf((node as React.ReactElement).props.children);
  }
  return "";
}

function execCommandCopy(text: string): void {
  const ta = document.createElement("textarea");
  ta.value = text;
  ta.style.position = "fixed";
  ta.style.opacity = "0";
  document.body.appendChild(ta);
  ta.select();
  document.execCommand("copy");
  ta.remove();
}

export function copyText(text: string): void {
  // goty:// is not a secure context — navigator.clipboard can be absent
  // in WKWebView; degrade to the execCommand path.
  if (navigator.clipboard?.writeText) {
    navigator.clipboard.writeText(text).catch(() => execCommandCopy(text));
  } else {
    execCommandCopy(text);
  }
}

/// Code-block frame for agent markdown (monocode/happier pattern):
/// language header + copy (1.2s check) around the hljs body — the
/// highlighting stays rehype-highlight so every token keeps coming from
/// the Ghostty-bridged palette.
export function AgentCodeBlock({ children, ...rest }: React.ComponentPropsWithoutRef<"pre">) {
  const [copied, setCopied] = useState(false);
  const child = Array.isArray(children) ? children[0] : children;
  const cls = child != null && typeof child === "object" && "props" in child
    ? String((child as React.ReactElement).props.className ?? "") : "";
  const lang = /language-([\w+#-]+)/.exec(cls)?.[1] ?? "";
  const lineCount = useMemo(
    () => codeTextOf(children).replace(/\n$/, "").split("\n").length,
    [children]);
  return (
    <div className="code-block">
      <div className="code-head">
        <span className="code-lang">{lang || "text"}</span>
        <button type="button" className="code-copy"
          onClick={() => {
            copyText(codeTextOf(children));
            setCopied(true);
            setTimeout(() => setCopied(false), 1200);
          }}>
          {copied ? "✓ 已复制" : "复制"}
        </button>
      </div>
      <pre {...rest}>
        {/* beautifului #18 code block: a line-number gutter column.
            Counts come from the code's text — the hljs spans ride
            untouched in the second column. */}
        <span className="code-nums" aria-hidden>
          {Array.from({ length: lineCount }, (_, i) => <span key={i}>{i + 1}</span>)}
        </span>
        {children}
      </pre>
    </div>
  );
}

export const streamdownProps = {
  mode: "streaming" as const,
  rehypePlugins: [rehypeHighlight],
  components: { pre: AgentCodeBlock },
};


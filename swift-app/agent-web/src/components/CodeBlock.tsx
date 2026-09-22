import React, { useMemo, useState } from "react";
import { postToHost } from "../bridge";
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

/// Inline code that IS a file reference (`/abs/path`, `~/…`, `./rel`,
/// `src/foo.rs`) becomes a clickable chip — the host opens it in the
/// built-in editor. Block code (hljs className) passes through.
function InlineCode(props: React.ComponentProps<"code">) {
  const className = props.className ?? "";
  if (className.includes("hljs") || className.includes("language-")) {
    return <code {...props} />;
  }
  const text = codeTextOf(props.children);
  if (looksLikeFilePath(text)) {
    return (
      <code
        {...props}
        className={(className ? className + " " : "") + "code-path"}
        title="在编辑器中打开"
        onClick={() => postToHost({ type: "openFile", path: text })}
      />
    );
  }
  return <code {...props} />;
}

/// Conservative: anchored at /, ~/, ./ or ../; must look like one path
/// token (no spaces, has a slash beyond the anchor, plausibly a name).
export function looksLikeFilePath(text: string): boolean {
  if (!text || /\s/.test(text) || text.length > 512) return false;
  if (/^[A-Za-z0-9_.-]+$/.test(text)) return false;     // bare word / filename
  if (/^(\/|~\/|\.\.?\/)/.test(text)) return (text.match(/\//g) ?? []).length >= 2;
  // Unanchored (repo-relative): needs depth AND a known extension —
  // `swift-app/Sources/App/AppDelegate.swift` yes, `a/b` no.
  return (text.match(/\//g) ?? []).length >= 2
      && /\.[A-Za-z][A-Za-z0-9]{0,5}$/.test(text)
      && /\.(swift|ts|tsx|js|jsx|mjs|css|html|json|md|rs|py|toml|ya?ml|sh|zsh|bash|txt|c|h|m|mm|go|java|kt|rb|php|vue|svelte|sql|lock|plist|cfg|conf|ini|zig|nix)$/i.test(text);
}

/// streamdown's default link renders a confirmation BUTTON
/// (linkSafety) with its own underline/primary classes — inside our
/// chrome that reads as a misplaced white pill. We own the anchor:
/// goty styling, click intercepted and routed to the host browser.
function LinkAnchor({ href, children, ...rest }: React.ComponentProps<"a">) {
  const incomplete = href === "streamdown:incomplete-link" || !href;
  return (
    <a
      {...rest}
      href={href}
      className={(rest.className ? rest.className + " " : "") + "md-link"}
      onClick={(e) => {
        if (incomplete) return;
        e.preventDefault();
        postToHost({ type: "openURL", url: href });
      }}
    >{children}</a>
  );
}

export const streamdownProps = {
  mode: "streaming" as const,
  rehypePlugins: [rehypeHighlight],
  components: { pre: AgentCodeBlock, code: InlineCode, a: LinkAnchor },
};


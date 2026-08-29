import { memo } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import rehypeHighlight from "rehype-highlight";
import { post } from "./bridge";

/// Markdown preview — the live editor text, re-rendered debounced by
/// the parent (tty7 reads its input live; same rule). Links route to
/// Swift (`NSWorkspace.open`) so the page never navigates away.
export const MarkdownPreview = memo(function MarkdownPreview({ text }: { text: string }) {
  return (
    <div className="md-preview">
      <ReactMarkdown
        remarkPlugins={[remarkGfm]}
        rehypePlugins={[[rehypeHighlight, { detect: false }]]}
        components={{
          a: ({ href, children }) => (
            <a
              href={href}
              onClick={(e) => {
                e.preventDefault();
                if (href) post({ type: "link", url: href });
              }}
            >
              {children}
            </a>
          ),
        }}
      >
        {text}
      </ReactMarkdown>
    </div>
  );
});

import { memo, useMemo } from "react";
import hljs from "highlight.js/lib/common";
import { parsePatch, type DiffHunk, type DiffLine } from "./diffParse";
import { hljsLanguageFor } from "./languages";

/// Split one highlighted HTML block into per-line HTML, re-opening
/// spans cut by the newline (highlight.js emits tags that may wrap
/// line breaks).
function highlightLines(code: string, lang: string | null): string[] {
  if (code.length === 0) return [];
  let html: string;
  try {
    html = lang && hljs.getLanguage(lang)
      ? hljs.highlight(code, { language: lang, ignoreIllegals: true }).value
      : escapeHtml(code);
  } catch {
    html = escapeHtml(code);
  }
  const out: string[] = [];
  let current = "";
  const openTags: string[] = [];
  let i = 0;
  while (i < html.length) {
    const ch = html[i];
    if (ch === "<") {
      const close = html.indexOf(">", i);
      if (close === -1) { current += html.slice(i); break; }
      const tag = html.slice(i, close + 1);
      current += tag;
      if (tag.startsWith("</")) {
        openTags.pop();
      } else if (!tag.endsWith("/>")) {
        openTags.push(tag);
      }
      i = close + 1;
      continue;
    }
    if (ch === "\n") {
      for (let t = openTags.length - 1; t >= 0; t--) current += "</span>";
      out.push(current);
      current = openTags.join("");
      i++;
      continue;
    }
    current += ch;
    i++;
  }
  out.push(current);
  return out;
}

function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

type PreparedHunk = {
  header: string;
  oldHtml: string[];
  newHtml: string[];
  /// Split rows: indexes into oldHtml/newHtml; null = empty cell.
  splitRows: { left: number | null; right: number | null;
               leftNo: number; rightNo: number }[];
  /// Unified rows.
  unified: { type: DiffLine["type"]; oldNo: number; newNo: number;
             html: string }[];
};

function prepareHunk(hunk: DiffHunk, lang: string | null): PreparedHunk {
  const oldRaw: string[] = [];
  const newRaw: string[] = [];
  const oldIdx = new Map<DiffLine, number>();
  const newIdx = new Map<DiffLine, number>();
  for (const line of hunk.lines) {
    if (line.type === "del" || line.type === "ctx") {
      oldIdx.set(line, oldRaw.length);
      oldRaw.push(line.text);
    }
    if (line.type === "add" || line.type === "ctx") {
      newIdx.set(line, newRaw.length);
      newRaw.push(line.text);
    }
  }
  const oldHtml = highlightLines(oldRaw.join("\n"), lang);
  const newHtml = highlightLines(newRaw.join("\n"), lang);

  // Split pairing: a del block aligns against the add block that
  // follows it (tty7's row pairing trade — no intra-line matching).
  const splitRows: PreparedHunk["splitRows"] = [];
  const unified: PreparedHunk["unified"] = [];
  let pendingDels: DiffLine[] = [];
  const flushDels = () => {
    for (const d of pendingDels) {
      splitRows.push({ left: oldIdx.get(d) ?? null, right: null,
                       leftNo: d.oldNo, rightNo: 0 });
    }
    pendingDels = [];
  };
  for (const line of hunk.lines) {
    if (line.type === "del") {
      pendingDels.push(line);
    } else if (line.type === "add") {
      const paired = pendingDels.shift() ?? null;
      splitRows.push({
        left: paired ? (oldIdx.get(paired) ?? null) : null,
        right: newIdx.get(line) ?? null,
        leftNo: paired?.oldNo ?? 0,
        rightNo: line.newNo,
      });
    } else {
      flushDels();
      splitRows.push({
        left: oldIdx.get(line) ?? null, right: newIdx.get(line) ?? null,
        leftNo: line.oldNo, rightNo: line.newNo,
      });
    }
    const side = line.type === "del"
      ? oldHtml[oldIdx.get(line) ?? 0]
      : newHtml[newIdx.get(line) ?? 0];
    unified.push({
      type: line.type,
      oldNo: line.oldNo,
      newNo: line.newNo,
      html: side ?? escapeHtml(line.text),
    });
  }
  flushDels();
  return { header: hunk.header, oldHtml, newHtml, splitRows, unified };
}

function splitRowClass(left: number | null, right: number | null): string {
  if (left != null && right != null) return "diff-row-ctx";
  if (right != null) return "diff-row-add";
  return "diff-row-del";
}

export const DiffView = memo(function DiffView(
  { patch, path, view }: { patch: string; path: string; view: "split" | "unified" }) {
  const diff = useMemo(() => parsePatch(patch), [patch]);
  const lang = diff ? hljsLanguageFor(diff.newPath || path) : null;
  const hunks = useMemo(
    () => diff ? diff.hunks.map((h) => prepareHunk(h, lang)) : [],
    [diff, lang]);

  if (!diff) {
    return <div className="diff-empty">No textual changes</div>;
  }
  if (diff.binary) {
    return <div className="diff-empty">Binary file — no line diff</div>;
  }

  return (
    <div className="diff">
      <div className="diff-filehead">
        <span className="diff-path">{diff.newPath || path}</span>
        <span className="diff-stat diff-stat-add">+{diff.added}</span>
        <span className="diff-stat diff-stat-del">−{diff.removed}</span>
        {diff.truncated && <span className="diff-truncated">first 4,000 lines shown</span>}
      </div>
      {hunks.map((h, hi) => (
        <div key={hi} className="diff-hunk">
          <div className="diff-hunkhead">{h.header}</div>
          {view === "split" ? (
            <table className="diff-table diff-split">
              <tbody>
                {h.splitRows.map((r, ri) => (
                  <tr key={ri} className={splitRowClass(r.left, r.right)}>
                    <td className="diff-no">{r.leftNo || ""}</td>
                    <td className="diff-code diff-left"
                        dangerouslySetInnerHTML={{
                          __html: r.left != null ? (h.oldHtml[r.left] ?? "") : "" }} />
                    <td className="diff-no">{r.rightNo || ""}</td>
                    <td className="diff-code diff-right"
                        dangerouslySetInnerHTML={{
                          __html: r.right != null ? (h.newHtml[r.right] ?? "") : "" }} />
                  </tr>
                ))}
              </tbody>
            </table>
          ) : (
            <table className="diff-table diff-unified">
              <tbody>
                {h.unified.map((r, ri) => (
                  <tr key={ri} className={`diff-row-${r.type}`}>
                    <td className="diff-no">{r.oldNo || ""}</td>
                    <td className="diff-no">{r.newNo || ""}</td>
                    <td className="diff-marker">
                      {r.type === "add" ? "+" : r.type === "del" ? "−" : ""}
                    </td>
                    <td className="diff-code"
                        dangerouslySetInnerHTML={{ __html: r.html }} />
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
      ))}
    </div>
  );
});

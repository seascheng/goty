/// Unified-patch parser (`git diff -U3` output). Pure; mirrors
/// tty7-core's probe_diff shapes trimmed to what the view needs.

export type DiffLineType = "add" | "del" | "ctx" | "meta";

export type DiffLine = {
  type: DiffLineType;
  text: string;
  /// 1-based source line numbers; 0 = none (meta / added-only …).
  oldNo: number;
  newNo: number;
};

export type DiffHunk = {
  header: string;
  oldStart: number;
  newStart: number;
  lines: DiffLine[];
};

export type FileDiff = {
  oldPath: string;
  newPath: string;
  hunks: DiffHunk[];
  added: number;
  removed: number;
  binary: boolean;
  /// Parser stopped at the line cap — the view says so.
  truncated: boolean;
};

const LINE_CAP = 4000;

export function parsePatch(patch: string): FileDiff | null {
  const lines = patch.split("\n");
  if (lines.length === 0) return null;
  let oldPath = "";
  let newPath = "";
  let added = 0;
  let removed = 0;
  let binary = false;
  const hunks: DiffHunk[] = [];
  let hunk: DiffHunk | null = null;
  let oldNo = 0;
  let newNo = 0;
  let kept = 0;

  for (const line of lines) {
    if (line.startsWith("diff --git ")) {
      const m = line.match(/^diff --git a\/(.*) b\/(.*)$/);
      if (m) { oldPath = m[1]; newPath = m[2]; }
      hunk = null;
      continue;
    }
    if (line.startsWith("Binary files ") || line.startsWith("GIT binary patch")) {
      binary = true;
      continue;
    }
    if (line.startsWith("--- ")) {
      const p = line.slice(4).replace(/^a\//, "");
      if (p !== "/dev/null") oldPath = p;
      continue;
    }
    if (line.startsWith("+++ ")) {
      const p = line.slice(4).replace(/^b\//, "");
      if (p !== "/dev/null") newPath = p;
      continue;
    }
    const hm = line.match(/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$/);
    if (hm) {
      oldNo = parseInt(hm[1], 10);
      newNo = parseInt(hm[3], 10);
      hunk = { header: line, oldStart: oldNo, newStart: newNo, lines: [] };
      hunks.push(hunk);
      continue;
    }
    if (hunk === null) continue; // index/rename/mode metadata lines
    if (kept >= LINE_CAP) {
      // Keep counting, stop retaining — stats stay true, DOM stays sane.
      if (line.startsWith("+") && !line.startsWith("+++")) added++;
      else if (line.startsWith("-") && !line.startsWith("---")) removed++;
      continue;
    }
    kept++;
    if (line.startsWith("+")) {
      hunk.lines.push({ type: "add", text: line.slice(1), oldNo: 0, newNo });
      newNo++; added++;
    } else if (line.startsWith("-")) {
      hunk.lines.push({ type: "del", text: line.slice(1), oldNo, newNo: 0 });
      oldNo++; removed++;
    } else if (line.startsWith("\\")) { // "\ No newline at end of file"
      hunk.lines.push({ type: "meta", text: line, oldNo: 0, newNo: 0 });
    } else {
      hunk.lines.push({ type: "ctx", text: line.slice(1), oldNo, newNo });
      oldNo++; newNo++;
    }
  }

  if (hunks.length === 0 && !binary && added + removed === 0) return null;
  return { oldPath, newPath, hunks, added, removed, binary,
           truncated: kept >= LINE_CAP };
}

/// Old/new side assembly for syntax highlighting and split pairing:
/// contiguous del-then-add runs become aligned rows (no intra-line
/// matching — same trade tty7's row pairing makes).
export type SplitRow = {
  left: DiffLine | null;
  right: DiffLine | null;
};

export function splitRows(hunk: DiffHunk): SplitRow[] {
  const rows: SplitRow[] = [];
  let pendingDels: DiffLine[] = [];
  const flush = () => {
    if (pendingDels.length === 0) return;
    for (const d of pendingDels) rows.push({ left: d, right: null });
    pendingDels = [];
  };
  for (const line of hunk.lines) {
    switch (line.type) {
      case "del":
        pendingDels.push(line);
        break;
      case "add":
        if (pendingDels.length > 0) {
          rows.push({ left: pendingDels.shift()!, right: line });
        } else {
          rows.push({ left: null, right: line });
        }
        break;
      default:
        flush();
        rows.push({ left: line, right: line.type === "ctx" ? line : null });
    }
  }
  flush();
  return rows;
}

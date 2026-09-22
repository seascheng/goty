import React, { useState } from "react";
import { store } from "../store";
import { postToHost } from "../bridge";

/// beautifului #04 approval card: a floating QUESTION card, not a bare
/// list — iconed header, queue position, quiet options. (confirm), or a text entry (input/editor — ask "Other" answers).
export function PermissionCard({ permission }: {
  permission: NonNullable<typeof store.permission>;
}) {
  const [value, setValue] = useState(permission.defaultValue ?? "");
  const isInput = permission.dialog === "input" || permission.dialog === "editor";
  const kind = permission.dialog === "select" ? "选择"
    : permission.dialog === "confirm" ? "确认"
    : isInput ? "输入" : "授权";
  const multi = permission.multi === true;
  const checked = new Set(permission.checkedIndices ?? []);
  // codex/bash confirmations put the whole command in toolCallTitle.
  // A long or multiline title IS the command body — show it in a
  // mono block and keep the header a short question.
  const rawTitle = permission.toolCallTitle ?? "";
  const isCommandBody = !isInput && !multi
    && (rawTitle.includes("\n") || rawTitle.length > 48);
  const question = isCommandBody ? "需要授权执行此命令" : rawTitle || "需要授权";
  // Short flat options (允许 / 本会话总是允许 / 拒绝) read as a button
  // row — macOS dialog language, primary/secondary/danger. Long or
  // detailed options keep the full-width list rows.
  const asButtons = !multi && permission.options.length <= 3
    && permission.options.every(o => !o.detail && o.name.length <= 12);
  const btnTone = (name: string) => {
    const n = name.trim();
    // "本会话总是允许" contains 允许 — match short consents exactly.
    if (/^(允许|同意|继续|allow|approve|accept|yes|continue|ok)$/i.test(n)) return " primary";
    if (/拒绝|不允许|deny|reject|cancel|取消|停止|abort/i.test(n)) return " danger";
    return "";
  };
  return (
    <div className="permission">
      <div className="perm-title">
        <span className="perm-glyph" aria-hidden>
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none"
            stroke="currentColor" strokeWidth="2" strokeLinecap="round"
            strokeLinejoin="round">
            <circle cx="12" cy="12" r="10" />
            <path d="M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3" />
            <line x1="12" y1="17" x2="12.01" y2="17" />
          </svg>
        </span>
        <span className="perm-question">{question}</span>
        <span className="perm-kind">{kind}</span>
        {(permission.pendingCount ?? 1) > 1 && (
          <span className="perm-queue" title="codex 已排队的授权请求数">
            第 1 / {permission.pendingCount} 个待授权
          </span>
        )}
      </div>
      {isCommandBody && (
        <pre className="perm-command"><code>{rawTitle}</code></pre>
      )}
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
      ) : asButtons ? (
        <div className="perm-actions">
          {permission.options.map((o, index) => (
            <button key={index} type="button"
              className={"perm-btn" + btnTone(o.name)}
              onClick={() => postToHost({ type: "permission", optionId: o.optionId })}>
              {o.name}
            </button>
          ))}
        </div>
      ) : (
        <div className="perm-options">
          {multi && (
            <div className="perm-multi-hint">
              多选:点击选项切换勾选,选完后点「完成选择」提交
            </div>
          )}
          {permission.options.map((o, index) => {
            const isDone = o.kind === "done";
            const isChecked = multi && checked.has(index);
            const rowCls = "perm-opt"
              + (isChecked ? " checked" : "")
              + (isDone ? " done" : "")
              + (multi && !isDone ? " toggle" : "");
            return (
              <button key={index} type="button" className={rowCls}
                title={o.detail ?? undefined}
                onClick={() => postToHost({ type: "permission", optionId: o.optionId })}>
                {(multi && !isDone) ? (
                  <span className="perm-box" aria-hidden>{isChecked ? "✓" : ""}</span>
                ) : isDone ? (
                  <span className="perm-done-ic" aria-hidden>✅</span>
                ) : null}
                <span className="perm-opt-name">{o.name}</span>
                {o.detail && <span className="perm-opt-detail">{o.detail}</span>}
              </button>
            );
          })}
        </div>
      )}
    </div>
  );
}

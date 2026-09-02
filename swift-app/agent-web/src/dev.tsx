// Dev-only harness: renders the real App against a seeded store so the
// agent GUI can be iterated on in a plain browser — no WKWebView, no
// live agent. NOT part of the production bundle (vite builds index.html
// only; this entry exists for `vite dev /dev.html`).
import React from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import { store } from "./store";
import "./styles.css";

declare global {
  interface Window {
    __goty: { push(events: unknown[]): void };
  }
}

window.__goty = {
  push(events: unknown[]) {
    store.applyAll(events);
  },
};

const seeds: unknown[] = [
  // Dark defaults mirroring the first-paint palette in styles.css.
  { type: "theme", vars: {
    mode: "dark",
    "surface0": "#181b1a",
    "foreground": "#e8eae9",
    "fg-muted": "#a1a5a4",
    "accent": "#20744a",
    "accent-bright": "#7ccba0",
    "destructive": "#c64f43",
    "border": "#252b2a",
    "border-accent": "#2f3534",
  } },
  { type: "meta", workspace: "goty", directory: "agent-web", branch: "new-gui",
    icon: "data:image/svg+xml;utf8,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'%3E%3Ccircle cx='12' cy='12' r='10' fill='%2320744a'/%3E%3Ctext x='12' y='16' text-anchor='middle' fill='white' font-size='12'%3Eg%3C/text%3E%3C/svg%3E" },
  { type: "sessionTitle", title: "GUI 实验 · 模型选择弹层" },
  { type: "plan", entries: [
    { content: "移植弹层组件", priority: "Phase 1", status: "completed" },
    { content: "重塑输入框", priority: "Phase 2", status: "in_progress" },
    { content: "验证键盘导航", priority: "Phase 2", status: "pending" }] },
  { type: "configOptions", options: [
    { id: "model", name: "模型", currentValue: "claude-sonnet-4-6",
      options: [
        { value: "claude-opus-4-6", name: "Claude Opus 4.6", source: "subscription" },
        { value: "claude-sonnet-4-6", name: "Claude Sonnet 4.6", source: "subscription" },
        { value: "claude-haiku-4-2", name: "Claude Haiku 4.2", source: "subscription" },
        { value: "glm-5.3", name: "GLM 5.3", source: "api" },
        { value: "glm-5.3-air", name: "GLM 5.3 Air", source: "api" },
        { value: "gpt-5.4", name: "GPT-5.4", source: "api" },
        { value: "gpt-5.4-mini", name: "GPT-5.4 mini", source: "api" },
        { value: "grok-4-fast", name: "Grok 4 Fast", source: "api" },
        { value: "gemini-3-pro", name: "Gemini 3 Pro", source: "api" },
        { value: "kimi-k3", name: "Kimi K3", source: "api" },
        { value: "qwen4-max", name: "Qwen4 Max", source: "api" },
        { value: "deepseek-v4", name: "DeepSeek V4", source: "api" },
        { value: "minimax-m3", name: "MiniMax M3", source: "api" },
      ] },
    { id: "thinking", name: "思考", currentValue: "medium",
      options: [
        { value: "off", name: "关闭" },
        { value: "low", name: "低" },
        { value: "medium", name: "中" },
        { value: "high", name: "高" },
      ] },
    { id: "mode", name: "权限", currentValue: "default",
      options: [
        { value: "read-only", name: "只读" },
        { value: "default", name: "默认" },
        { value: "acceptEdits", name: "接受编辑" },
        { value: "bypass", name: "跳过确认" },
      ] },
  ] },
  { type: "sessions", sessions: [
    { sessionId: "s1", title: "修 sessiond 重连竞态", messageCount: 42, updatedAt: "1788270706" },
    { sessionId: "s2", title: "Agent GUI 主题桥", messageCount: 17, updatedAt: "1788184306" },
    { sessionId: "s3", title: null, messageCount: 3, updatedAt: "1788097906" },
    { sessionId: "s4", title: "远端 daemon 升级", messageCount: 88, updatedAt: "1788011506" },
  ] },
  { type: "commands", commands: [
    { name: "compact", description: "压缩上下文", inputHint: null },
    { name: "clear", description: "清空会话", inputHint: null },
    { name: "model", description: "切换模型", inputHint: "<name>" },
    { name: "export", description: "导出会话 HTML", inputHint: null },
  ] },
  { type: "files", files: [
    "src/App.tsx", "src/store.ts", "src/styles.css", "src/ui/Popover.tsx",
    "src/lib/popover.ts", "package.json", "vite.config.ts",
  ] },
  { type: "usage", input: 18400, output: 3200, used: 21600, size: 200000 },
  { type: "runtimeStatus", fastEnabled: true, fastActive: false,
    contextTokens: 21600, contextWindow: 200000 },

  { type: "userMessage", text: "把 monocode 的模型弹层搬过来，样式要跟 Ghostty 主题走。" },
  { type: "thoughtChunk", text: "用户要的是三件事：定位数学、玻璃表面、键盘导航。token 桥已经在 styles.css 里了。" },
  { type: "chunkBoundary" },
  { type: "agentChunk", text: "好，分三步：\n\n1. **定位数学** `popover.ts` 纯函数可直接移植\n2. **表面** 用 `.pop-surface` 桥接宿主 token\n3. **交互** 170ms 弹入 + 搜索行\n\n```ts\nconst next = placePopover(rect, size, viewport, { side: \"top\" });\n```\n\n| 组件 | 来源 | 状态 |\n|---|---|---|\n| Popover | monocode | ✅ |\n| 行样式 | monocode | ✅ |\n| 主题 | Ghostty | 桥接 |" },
  { type: "toolCall", id: "t1", title: null, kind: "read", status: "completed",
    rawInput: { path: "src/chrome/Popover.tsx" },
    content: [{ type: "text", text: "254 lines, MIT" }], output: [] },
  { type: "toolCall", id: "t2", title: null, kind: "edit", status: "in_progress",
    rawInput: { path: "src/styles.css", content: "/* glass surface */\n.pop-surface { border-radius: 12px; }" },
    oldText: "/* plain surface */\n.pop-surface { border-radius: 8px; }",
    content: [], output: [] },
  { type: "toolCall", id: "t3", title: null, kind: "edit", status: "completed",
    rawInput: null,
    content: [{ type: "diff", path: "src/ui/Popover.tsx",
      oldText: "export function Popover(props: PopoverProps) {",
      newText: "export function Popover(props: PopoverProps): ReactNode {" }],
    output: [] },
  { type: "toolCall", id: "t4", title: null, kind: "edit", status: "completed",
    rawInput: null,
    content: [{ type: "diff", path: "src/styles.css",
      patch: "diff --git a/src/styles.css b/src/styles.css\n--- a/src/styles.css\n+++ b/src/styles.css\n@@ -12,3 +12,4 @@\n .pop-surface {\n   border-radius: 12px;\n+  box-shadow: 0 8px 24px rgba(0,0,0,.35);\n   background: var(--surface0);\n }" }],
    output: [] },
  { type: "toolCall", id: "t5", title: null, kind: "edit", status: "completed",
    rawInput: null,
    content: [{ type: "diff", path: "/Users/seascheng/ai/agent-web/src/styles.css",
      text: " 314|.composer textarea {\n\n 317|  padding: 12px 6px 4px; min-height: 58px; display: block;\n-319|.composer textarea::placeholder { color: var(--fg-extra-muted); }\n+319|.composer textarea::placeholder {\n+320|  color: var(--fg-extra-muted);\n+321|  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;\n+322|}\n 320|/* — composer toolbar: pill knobs (left) · meta/usage/action (right) — */" }],
    output: [] },
  { type: "working", value: false },
];

store.applyAll(seeds);

const root = createRoot(document.getElementById("root")!);
root.render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);

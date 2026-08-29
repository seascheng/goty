import { StreamLanguage } from "@codemirror/language";
import { swift } from "@codemirror/legacy-modes/mode/swift";
import { yaml } from "@codemirror/legacy-modes/mode/yaml";
import { toml } from "@codemirror/legacy-modes/mode/toml";
import { shell } from "@codemirror/legacy-modes/mode/shell";
import { diff } from "@codemirror/legacy-modes/mode/diff";
import { ruby } from "@codemirror/legacy-modes/mode/ruby";
import { perl } from "@codemirror/legacy-modes/mode/perl";
import { lua } from "@codemirror/legacy-modes/mode/lua";
import { powerShell } from "@codemirror/legacy-modes/mode/powershell";
import { dockerFile } from "@codemirror/legacy-modes/mode/dockerfile";
import { objectiveC, csharp, scala, kotlin } from "@codemirror/legacy-modes/mode/clike";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { javascriptLanguage } from "@codemirror/lang-javascript";
import { json } from "@codemirror/lang-json";
import { python } from "@codemirror/lang-python";
import { rust } from "@codemirror/lang-rust";
import { cpp } from "@codemirror/lang-cpp";
import { go } from "@codemirror/lang-go";
import { java } from "@codemirror/lang-java";
import { html } from "@codemirror/lang-html";
import { css } from "@codemirror/lang-css";
import { sql } from "@codemirror/lang-sql";
import type { Extension } from "@codemirror/state";

/// Static ext→mode table — tty7's curated language_for_path model, not
/// the 130-mode lazy pack (every mode inlines into the single-file
/// bundle; the pack would add megabytes).
const LANGUAGES: Record<string, () => Extension> = {
  md: () => markdown(),
  markdown: () => markdown(),
  js: () => javascriptLanguage,
  mjs: () => javascriptLanguage,
  cjs: () => javascriptLanguage,
  jsx: () => javascriptLanguage,
  ts: () => javascriptLanguage,
  mts: () => javascriptLanguage,
  cts: () => javascriptLanguage,
  tsx: () => javascriptLanguage,
  json: () => json(),
  jsonc: () => json(),
  py: () => python(),
  pyi: () => python(),
  rs: () => rust(),
  c: () => cpp(),
  h: () => cpp(),
  cc: () => cpp(),
  cpp: () => cpp(),
  cxx: () => cpp(),
  hpp: () => cpp(),
  hh: () => cpp(),
  go: () => go(),
  java: () => java(),
  swift: () => StreamLanguage.define(swift),
  m: () => StreamLanguage.define(objectiveC),
  mm: () => StreamLanguage.define(objectiveC),
  cs: () => StreamLanguage.define(csharp),
  lua: () => StreamLanguage.define(lua),
  ps1: () => StreamLanguage.define(powerShell),
  kts: () => StreamLanguage.define(kotlin),
  rb: () => StreamLanguage.define(ruby),
  pl: () => StreamLanguage.define(perl),
  pm: () => StreamLanguage.define(perl),
  html: () => html(),
  htm: () => html(),
  xhtml: () => html(),
  css: () => css(),
  scss: () => css(),
  less: () => css(),
  sql: () => sql(),
  sh: () => StreamLanguage.define(shell),
  bash: () => StreamLanguage.define(shell),
  zsh: () => StreamLanguage.define(shell),
  fish: () => StreamLanguage.define(shell),
  yml: () => StreamLanguage.define(yaml),
  yaml: () => StreamLanguage.define(yaml),
  toml: () => StreamLanguage.define(toml),
  patch: () => StreamLanguage.define(diff),
  diff: () => StreamLanguage.define(diff),
};

export function languageFor(path: string): Extension | null {
  const ext = path.slice(path.lastIndexOf(".") + 1).toLowerCase();
  const make = LANGUAGES[ext === path ? "" : ext];
  return make ? make() : null;
}

/// rehype-highlight / diff-side language id for highlight.js, from the
/// same table's vocabulary (aliases highlight.js understands).
export function hljsLanguageFor(path: string): string | null {
  const ext = path.slice(path.lastIndexOf(".") + 1).toLowerCase();
  if (ext === path) return null;
  const ALIASES: Record<string, string> = {
    md: "markdown", markdown: "markdown",
    mjs: "javascript", cjs: "javascript", jsx: "javascript",
    mts: "typescript", cts: "typescript", tsx: "typescript",
    jsonc: "json",
    pyi: "python",
    cc: "cpp", cxx: "cpp", hpp: "cpp", hh: "cpp",
    m: "objectivec", mm: "objectivec",
    sc: "scala", kts: "kotlin",
    pm: "perl",
    ps1: "powershell",
    htm: "xml", xhtml: "xml", vue: "xml",
    scss: "scss", less: "less",
    sh: "bash", zsh: "bash", fish: "bash",
    yml: "yaml",
    patch: "diff",
  };
  return ALIASES[ext] ?? ext;
}

export { markdownLanguage };

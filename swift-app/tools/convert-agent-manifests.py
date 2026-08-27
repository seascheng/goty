#!/usr/bin/env python3
"""Convert agent-detection manifests (TOML) into a Swift source file.

Source of truth: the upstream manifests workspace's *.toml — the passive
screen/OSC rule engine (same semantics as src/detect/manifest.rs). We port
the rule semantics 1:1 and re-emit them as a compiled-in Swift table so the
engine needs no TOML parser and no bundle resources.

Usage:
    python3 tools/convert-agent-manifests.py <manifests-dir> > Sources/Core/AgentManifests.swift

Only agents present in our AgentCatalog are converted; AGENTS below maps a
manifest file stem to the AgentCatalog command key.
"""

import sys
import tomllib
from pathlib import Path

AGENTS = {
    "claude": ["claude", "claude-code"],
    "codex": ["codex"],
    "pi": ["pi"],
    "opencode": ["opencode"],
    "gemini": ["gemini"],
    "grok": ["grok"],
    "github-copilot": ["copilot"],
    "droid": ["droid"],
}


def swift_str(s: str) -> str:
    out = '"'
    for ch in s:
        if ch == '"':
            out += '\\"'
        elif ch == "\\":
            out += "\\\\"
        elif ch == "\n":
            out += "\\n"
        elif ch == "\t":
            out += "\\t"
        elif ch == "\r":
            out += "\\r"
        elif ord(ch) < 0x20:
            out += f"\\u{{{ord(ch):x}}}"
        else:
            out += ch
    return out + '"'


def emit_gate(gate: dict, indent: str) -> str:
    parts = []
    if gate.get("contains"):
        items = ", ".join(swift_str(s) for s in gate["contains"])
        parts.append(f"contains: [{items}]")
    if gate.get("regex"):
        items = ", ".join(swift_str(s) for s in gate["regex"])
        parts.append(f"regex: [{items}]")
    if gate.get("line_regex"):
        items = ", ".join(swift_str(s) for s in gate["line_regex"])
        parts.append(f"lineRegex: [{items}]")
    if gate.get("all"):
        parts.append("all: [" + ", ".join(emit_gate(g, indent) for g in gate["all"]) + "]")
    if gate.get("any"):
        parts.append("any: [" + ", ".join(emit_gate(g, indent) for g in gate["any"]) + "]")
    if gate.get("not"):
        parts.append("not: [" + ", ".join(emit_gate(g, indent) for g in gate["not"]) + "]")
    return "AgentMatchGate(" + ", ".join(parts) + ")"


def emit_rule(rule: dict, indent: str) -> str:
    parts = [
        f"id: {swift_str(rule['id'])}",
        f"state: .{rule['state']}",
        f"priority: {rule.get('priority', 0)}",
        f"region: {swift_str(rule.get('region', 'whole_recent'))}",
    ]
    if rule.get("visible_idle"):
        parts.append("visibleIdle: true")
    if rule.get("visible_blocker"):
        parts.append("visibleBlocker: true")
    if rule.get("visible_working"):
        parts.append("visibleWorking: true")
    if rule.get("skip_state_update"):
        parts.append("skipStateUpdate: true")
    parts.append(f"gate: {emit_gate(rule, indent)}")
    body = ", ".join(parts)
    return f"{indent}AgentManifestRule({body})"


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("usage: convert-agent-manifests.py <manifests-dir>")
    src = Path(sys.argv[1])
    entries = []
    versions = []
    for stem, keys in AGENTS.items():
        manifest = tomllib.loads((src / f"{stem}.toml").read_text())
        version = manifest.get("version", "")
        versions.append((", ".join(keys), stem, version))
        rules = ",\n".join(emit_rule(r, "            ") for r in manifest["rules"])
        for key in keys:
            entries.append(
                f'        "{key}": [\n{rules},\n        ]'
            )
    print("// goty — see CLAUDE.md for the working principles.")
    print("//")
    print("// GENERATED FILE — do not edit by hand. Regenerate with:")
    print("//   python3 tools/convert-agent-manifests.py <manifests-dir> > Sources/Core/AgentManifests.swift")
    print("//")
    print("// Passive agent-state rules (detection manifests, ported 1:1).")
    print("// Upstream versions:")
    for key, stem, version in versions:
        print(f"//   {key:9s} <- {stem}.toml {version}")
    print()
    print("/// Rules per AgentCatalog command key. Evaluated by AgentDetect.")
    print("let agentManifestTable: [String: [AgentManifestRule]] = [")
    print(",\n".join(entries))
    print("]")
    print()
    print("/// Agents that have no passive manifest here (omp, aider, …)")
    print("/// degrade to the known-agent idle fallback — badge only, no live state.")


if __name__ == "__main__":
    main()

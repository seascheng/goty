import React, { useSyncExternalStore } from "react";
import { store, type PlanEntry } from "../store";
import { LoaderGrid } from "./Loader";

/// Dock plan panel: pinned above the composer (TUI model), phase-
/// grouped, collapsible. The fold lives in the STORE, persisted to
/// localStorage: the dock remounts whenever plan/jobs flush to null
/// and back, and WKWebView can crash-reload the page — component or
/// module state resurrected the panel the user had folded, and the
/// taller dock then shoved the transcript (2026-09-02 report).
export function PlanPanel({ entries }: { entries: PlanEntry[] }) {
  // LOCAL subscription: togglePlanDock no longer bumps the store
  // revision, so folding re-renders ONLY this panel — never the whole
  // transcript (the reported fold jank).
  const open = useSyncExternalStore(
    (onChange) => store.subscribe(onChange),
    () => store.planDockOpen && !store.planFoldedBySettle,
    () => true,
  );
  const done = entries.filter((e) => e.status === "completed").length;
  const phases: { name: string | null; items: PlanEntry[] }[] = [];
  for (const e of entries) {
    const last = phases[phases.length - 1];
    if (last && last.name === (e.priority ?? null)) last.items.push(e);
    else phases.push({ name: e.priority ?? null, items: [e] });
  }
  return (
    <div className={"dock-plan" + (open ? "" : " folded")}>
      <button className="dock-head"
        onClick={() => store.togglePlanDock()}
        title={open ? "收起计划面板" : "展开计划面板"}>
        <span className="plan-title">计划</span>
        <span className="plan-progress">{done}/{entries.length}</span>
      </button>
      {/* The body ALWAYS mounts — folding animates the clip's grid row
          (0fr↔1fr) instead of unmounting, so the transcript's height
          change is a transition, not a jump. */}
      <div className="plan-clip">
        <div className="plan-body">
          {phases.map((phase, i) => (
            <div key={i} className="plan-phase">
              {phase.name && <div className="plan-phase-name">{phase.name}</div>}
              {phase.items.map((e, j) => (
                <div key={j} className={"plan-row " + (e.status ?? "")}>
                  {/* beautifului #06 task rows: a state mark per row —
                      green check, the pixel loader, or an empty ring. */}
                  <span className={"plan-mark " + (e.status ?? "")}>
                    {e.status === "completed" ? "✓"
                      : e.status === "in_progress" ? <LoaderGrid size={9} />
                      : null}
                  </span>
                  <span>{e.content}</span>
                </div>
              ))}
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}


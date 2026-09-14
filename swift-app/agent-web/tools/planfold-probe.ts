// Behavior probe for the settled-plan fold (2026-09-14 report):
// omp's get_state keeps serving the all-completed todoPhases forever
// after settle; the store must fold the plan at the next user block
// and must NOT let an identical repeated snapshot resurrect it.
import { store } from "../src/store.ts";

let failures = 0;
const check = (name: string, cond: boolean) => {
  if (!cond) { failures++; console.log("FAIL " + name); }
  else console.log("ok   " + name);
};

const snap = (n: number, status: string) => ({
  type: "plan",
  entries: Array.from({ length: n }, (_, i) => ({
    content: `task ${i + 1}`, priority: "Phase", status })),
});

// t1 — the reported scenario: all-completed plan, turn settles, the
// 2s poll keeps replaying the SAME snapshot, next message folds it.
store.apply(snap(10, "completed"));
check("t1 shows plan", store.plan != null && store.plan.entries.length === 10);
store.apply({ type: "turnEnded" });
check("t1 data survives settle (no mid-read jump)", store.plan != null);
store.apply(snap(10, "completed"));           // identical poll snapshot
store.apply({ type: "userMessage", text: "next" });
check("t1 folds after next message", store.plan == null);

// t2 — a CHANGED snapshot after settle is new information: it lands.
store.apply(snap(3, "pending"));
check("t2 changed snapshot lands", store.plan != null && store.plan.entries.length === 3);

// t3 — a partially-done plan survives settle + message (progress stays).
store.apply({ type: "plan", entries: [
  { content: "a", status: "completed" }, { content: "b", status: "in_progress" }] });
store.apply({ type: "turnEnded" });
store.apply({ type: "userMessage", text: "hi" });
check("t3 partial plan stays visible", store.plan != null
  && store.plan.entries.length === 2);

// t4 — queued delivery opens a turn too: folds a settled plan.
store.apply({ type: "plan", entries: [
  { content: "a", status: "completed" }, { content: "b", status: "completed" }] });
store.apply({ type: "turnEnded" });
store.apply({ type: "queueMessage", text: "queued" });
store.apply({ type: "plan", entries: [
  { content: "a", status: "completed" }, { content: "b", status: "completed" }] });
store.apply({ type: "queueDelivered", text: "queued" });
check("t4 queueDelivered folds settled plan", store.plan == null);

// t5 — mid-turn refresh of an all-completed plan keeps showing it
// (only the turn END arms the fold).
store.reset?.();
store.apply(snap(2, "completed"));
store.apply({ type: "working", value: true });
store.apply(snap(2, "completed"));
check("t5 mid-turn snapshot still shows", store.plan != null);

// t6 — webview reload replay: fresh store, agent idle, first snapshot
// is the stale all-completed one → data lands but presents FOLDED.
store.reset?.();
store.apply({ type: "working", value: false });
store.apply(snap(4, "completed"));
check("t6 reload replay presents folded", store.plan != null
  && store.planFoldedBySettle === true);

// t7 — the user's head click unfolds a settled plan (and re-arms on
// the next settle).
store.togglePlanDock();
check("t7 click unfolds settled plan", store.planFoldedBySettle === false);
store.apply({ type: "turnEnded" });
check("t7 next settle re-folds", store.planFoldedBySettle === true);

// t8 — settle folds the panel while the data stays (turn-end case).
store.reset?.();
store.apply({ type: "working", value: true });
store.apply(snap(2, "completed"));
check("t8 mid-turn all-completed stays open", store.planFoldedBySettle === false);
store.apply({ type: "turnEnded" });
check("t8 settle folds, data kept", store.planFoldedBySettle === true
  && store.plan != null);

// t9 — a later turn that rewrites the plan reopens it.
store.apply({ type: "userMessage", text: "go" });
store.apply({ type: "working", value: true });
store.apply(snap(3, "pending"));
check("t9 rewritten plan reopens", store.plan != null
  && store.planFoldedBySettle === false);
process.exit(failures === 0 ? 0 : 1);

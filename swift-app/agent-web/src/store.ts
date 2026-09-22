import { z } from "zod";
import { postToHost } from "./bridge";

/// Swift → JS events (AgentWebBridge). Schema-parsed once at this
/// boundary; Swift fills absent optionals with NSNull(), so absent string
/// fields arrive as `null` and stay nullable through the view layer.
export type ToolContent = { type: string; text?: string | null; path?: string | null;
  /// `{type:"diff"}` blocks (monocode harness parity): the agent ships
  /// pre/post edit text or a raw git patch with its tool call.
  oldText?: string | null; newText?: string | null; patch?: string | null };
export type ToolCall = {
  id: string; title?: string | null; kind?: string | null; status?: string | null;
  content: ToolContent[];
  /// Tool result (`rawOutput.content`, omp displayContent fallback) —
  /// what the flat-only Swift reader used to drop on resume.
  output: ToolContent[];
  rawInput?: Record<string, unknown> | null;
  oldText?: string | null;
};
export type PlanEntry = { content: string; priority?: string | null; status?: string | null };
export type JobRow = { id: string; kind: string; status: string;
  label: string; startTime?: number | null };
export type SubagentRow = { id: string; state?: string | null; detail?: string | null; at: number };
export type RuntimeState = { fastEnabled?: boolean | null; fastActive?: boolean | null;
  contextTokens?: number | null; contextWindow?: number | null;
  tokensPerSecond?: number | null; queued?: number | null;
  compacting?: boolean | null; streaming?: boolean | null };
export type Permission = { requestID: string; toolCallTitle?: string | null;
  options: { optionId: string; name: string; kind?: string | null; detail?: string | null }[];
  dialog?: string | null; placeholder?: string | null; defaultValue?: string | null;
  /** omp ask multi-select round: clicking toggles (agent re-asks with a
   * fresh card); checkedIndices are already-selected option positions;
   * a kind:"done" option commits the set. */
  multi?: boolean | null; checkedIndices?: number[] | null;
  /** Authorization requests queued behind this one (codex); >1 shows
   * a "第 1 / N 个待授权" position chip on the card. */
  pendingCount?: number | null };
type DistributiveOmit<T, K extends PropertyKey> = T extends unknown ? Omit<T, K> : never;
/// Structural equality for plan snapshots — the dedup key the plan
/// handler uses to ignore repeated identical snapshots (omp's get_state
/// polls keep serving the settled all-completed todoPhases).
function planEntriesEqual(a: PlanEntry[], b: PlanEntry[]): boolean {
  if (a === b) return true;
  if (a.length !== b.length) return false;
  return a.every((e, i) =>
      e.content === b[i].content && e.priority === b[i].priority
      && e.status === b[i].status);
}
/// A block before it gets its stable identity stamp.
type BlockInput = DistributiveOmit<Block, "id">;
export type Block =
  | { kind: "user"; id: number; text: string; entryId?: string }
  | { kind: "agent"; id: number; text: string; entryId?: string }
  | { kind: "thought"; id: number; text: string }
  | { kind: "tool"; id: number; call: ToolCall }
  | { kind: "turnStats"; id: number; text: string }
  | { kind: "error"; id: number; text: string }
  | { kind: "notice"; id: number; text: string }

/// Compact token counts (k/M/G), shared by the transcript's turn-stats
/// rows and the composer usage segments.
export function fmtTokens(n?: number | null): string {
  if (n == null) return "";
  if (n >= 1e9) return (n / 1e9).toFixed(1).replace(/\.0$/, "") + "G";
  if (n >= 1e6) return (n / 1e6).toFixed(1).replace(/\.0$/, "") + "M";
  if (n >= 1e3) return (n / 1e3).toFixed(1).replace(/\.0$/, "") + "k";
  return String(n);
}

const ToolContentSchema = z.object({
  type: z.string(),
  text: z.string().nullish(),
  path: z.string().nullish(),
  oldText: z.string().nullish(),
  newText: z.string().nullish(),
  patch: z.string().nullish(),
});
const PlanEntrySchema = z.object({
  content: z.string(),
  priority: z.string().nullish(),
  status: z.string().nullish(),
});
const PermissionOptionSchema = z.object({
  optionId: z.string(),
  name: z.string(),
  kind: z.string().nullish(),
  detail: z.string().nullish(),
});
export type AgentSessionSummary = {
  sessionId: string; cwd?: string | null; title?: string | null;
  updatedAt?: string | null; messageCount?: number | null;
};
const AgentSessionSummarySchema = z.object({
  sessionId: z.string(),
  cwd: z.string().nullish(),
  title: z.string().nullish(),
  updatedAt: z.string().nullish(),
  messageCount: z.number().nullish(),
});
const ConfigChoiceSchema = z.object({
  value: z.string(),
  name: z.string(),
  description: z.string().nullish(),
  source: z.string().nullish(),
});
export type ConfigChoice = z.infer<typeof ConfigChoiceSchema>;
const ConfigOptionSchema = z.object({
  id: z.string(),
  name: z.string(),
  category: z.string().nullish(),
  currentValue: z.string().nullish(),
  options: z.array(ConfigChoiceSchema),
});
export type ConfigOption = z.infer<typeof ConfigOptionSchema>;
const AgentCommandSchema = z.object({
  name: z.string(),
  description: z.string().nullish(),
  inputHint: z.string().nullish(),
});
export type AgentCommand = z.infer<typeof AgentCommandSchema>;

export const IncomingEventSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("userMessage"), text: z.string() }),
  z.object({ type: z.literal("queueMessage"), text: z.string() }),
  /// Pane-owned outbox actions (Swift is the queue authority; the
  /// pendingQueue here is a pure mirror driven by these events).
  z.object({ type: z.literal("queueRemoved"), text: z.string() }),
  z.object({ type: z.literal("queueDelivered"), text: z.string() }),
  z.object({ type: z.literal("userChunk"), text: z.string() }),
  z.object({ type: z.literal("agentChunk"), text: z.string() }),
  z.object({ type: z.literal("thoughtChunk"), text: z.string() }),
  z.object({ type: z.literal("chunkBoundary") }),
  z.object({ type: z.literal("historyTruncated"), truncated: z.boolean() }),
  z.object({ type: z.literal("transcriptPrepend"),
             events: z.array(z.record(z.string(), z.unknown())) }),
  z.object({
    type: z.literal("toolCall"),
    id: z.string(),
    title: z.string().nullish(),
    kind: z.string().nullish(),
    status: z.string().nullish(),
    content: z.array(ToolContentSchema).nullish(),
    output: z.array(ToolContentSchema).nullish(),
    rawInput: z.record(z.string(), z.unknown()).nullish(),
    oldText: z.string().nullish(),
  }),
  z.object({ type: z.literal("plan"), entries: z.array(PlanEntrySchema).nullish() }),
  z.object({
    type: z.literal("permission"),
    requestID: z.string(),
    toolCallTitle: z.string().nullish(),
    defaultValue: z.string().nullish(),
    multi: z.boolean().nullish(),
    checkedIndices: z.array(z.number()).nullish(),
    pendingCount: z.number().nullish(),
    options: z.array(PermissionOptionSchema),
    dialog: z.string().nullish(),
    placeholder: z.string().nullish(),
  }),
  z.object({ type: z.literal("permissionResolved"),
             requestID: z.string().nullish() }),
  z.object({ type: z.literal("phase"), value: z.string().nullish() }),
  z.object({ type: z.literal("statusFlash"), text: z.string() }),
  z.object({ type: z.literal("error"), text: z.string() }),
  z.object({
    type: z.literal("retryScheduled"),
    attempt: z.number().nullish(),
    maxAttempts: z.number().nullish(),
    delayMs: z.number().nullish(),
    errorText: z.string().nullish(),
  }),
  z.object({ type: z.literal("reconnecting"), value: z.boolean() }),
  z.object({ type: z.literal("turnEnded") }),
  z.object({ type: z.literal("branchState"), active: z.boolean() }),
  z.object({ type: z.literal("working"), value: z.boolean() }),
  z.object({ type: z.literal("starting"), agent: z.string() }),
  z.object({ type: z.literal("ready") }),
  z.object({ type: z.literal("status"), text: z.string() }),
  z.object({ type: z.literal("configOptions"), options: z.unknown().nullish() }),
  z.object({ type: z.literal("commands"), commands: z.unknown().nullish() }),
  z.object({
    type: z.literal("usage"),
    used: z.number().nullish(),
    size: z.number().nullish(),
    input: z.number().nullish(),
    output: z.number().nullish(),
    costAmount: z.number().nullish(),
    costCurrency: z.string().nullish(),
  }),
  z.object({ type: z.literal("sessions"), sessions: z.unknown().nullish() }),
  z.object({ type: z.literal("clearTranscript") }),
  z.object({ type: z.literal("files"), files: z.array(z.string()) }),
  z.object({
    type: z.literal("runtimeStatus"),
    fastEnabled: z.boolean().nullish(),
    fastActive: z.boolean().nullish(),
    contextTokens: z.number().nullish(),
    contextWindow: z.number().nullish(),
    tokensPerSecond: z.number().nullish(),
    queued: z.number().nullish(),
    compacting: z.boolean().nullish(),
    streaming: z.boolean().nullish(),
  }),
  z.object({
    type: z.literal("jobs"),
    jobs: z.array(z.object({
      id: z.string(),
      kind: z.string().nullish(),
      status: z.string().nullish(),
      label: z.string().nullish(),
      startTime: z.number().nullish(),
    })).nullish(),
  }),
  z.object({
    type: z.literal("subagent"),
    id: z.string(),
    state: z.string().nullish(),
    detail: z.string().nullish(),
  }),
  z.object({
    type: z.literal("entryMark"),
    role: z.string(),
    entryId: z.string(),
  }),
  z.object({ type: z.literal("stats"), stats: z.record(z.string(), z.unknown()) }),
  z.object({ type: z.literal("loginProviders"), providers: z.array(z.record(z.string(), z.unknown())) }),
  z.object({ type: z.literal("openURL"), url: z.string() }),
  z.object({
    type: z.literal("sessionTitle"),
    title: z.string().nullish(),
  }),
  z.object({ type: z.literal("theme"), vars: z.record(z.string(), z.string()) }),
  /// Host-owned plan-dock fold pref, pushed at page ready (and after
  /// every toggle): custom-scheme WKWebView localStorage does not
  /// survive loads, so NSUserDefaults is the source of truth.
  z.object({ type: z.literal("planDockPref"), open: z.boolean() }),
  z.object({
    type: z.literal("meta"),
    capabilities: z.array(z.string()).nullish(),
    workspace: z.string().nullish(),
    directory: z.string().nullish(),
    branch: z.string().nullish(),
    icon: z.string().nullish(),
  }),
]);

export type IncomingEvent = z.infer<typeof IncomingEventSchema>;

type Listener = () => void;

function parseEvent(raw: unknown): IncomingEvent | null {
  const result = IncomingEventSchema.safeParse(raw);
  return result.success ? result.data : null;
}

/// Per-item tolerant array coercion: one malformed entry drops itself,
/// never the whole batch.
function coerceList<T>(raw: unknown, schema: z.ZodType<T>): T[] {
  if (!Array.isArray(raw)) return [];
  return raw
    .map((item) => schema.safeParse(item))
    .filter((r) => r.success)
    .map((r) => r.data);
}

/// Events that definitively end the initial startup phase. Static lookup:
/// no per-event allocation on transcript replay.
const STARTING_TERMINATORS: Record<string, true> = {
  ready: true,
  status: true,
  plan: true,
  runtimeStatus: true,
  jobs: true,
  configOptions: true,
  commands: true,
  userMessage: true,
  userChunk: true,
  agentChunk: true,
  thoughtChunk: true,
  chunkBoundary: true,
  toolCall: true,
  permission: true,
  turnEnded: true,
  error: true,
};

class Store {
  blocks: Block[] = [];
  toolOrder: string[] = [];
  sessions: AgentSessionSummary[] = [];
  tools = new Map<string, ToolCall>();
  files: string[] = [];
  permission: Permission | null = null;
  /// Dock state — pinned between transcript and composer, never
  /// transcript blocks: plan (todoPhases), background jobs, subagents.
  plan: { entries: PlanEntry[] } | null = null;
  jobs: JobRow[] = [];
  subagents: SubagentRow[] = [];
  runtime: RuntimeState | null = null;
  /// Stats dialog payload (get_session_stats); null = closed.
  stats: Record<string, unknown> | null = null;
  working = false;
  /// Follow-ups queued while a turn ran (Enter mid-turn). omp delivers
  /// them after settle; they flush as user blocks at turnEnded.
  pendingQueue: string[] = [];
  /// True while a worktree fork (throwaway process) is booting — every
  /// BranchButton disables on it; the Swift handler holds the same flag.
  branchBusy = false;
  /// Set when the agent clears the plan at turn settle; the stale plan
  /// keeps the dock mounted (scroll-jump guard) until the next turn.
  private planCleared = false;
  /// A settled FULLY-completed plan also presents FOLDED, on top of
  /// the user's dock-fold pref (2026-09-14: the finished panel kept
  /// reappearing open — at settle, on later turns, and after webview
  /// reloads replaying the stale all-completed snapshot omp's get_state
  /// serves forever). The user's head click still unfolds it.
  private planSettledFold = false;
  /// View-facing: the plan panel must render folded (settled plan +
  /// the user has not just asked to see it).
  get planFoldedBySettle(): boolean { return this.planSettledFold; }
  /// Plan-dock fold. Lives in the STORE (not component state) and is
  /// persisted: the dock remounts whenever plan/jobs flush to null and
  /// back, and WKWebView can crash-reload the page — both used to
  /// resurrect the panel the user had folded.
  planDockOpen = (() => {
    try { return localStorage.getItem("goty.planDock.open") !== "0"; } catch { return true; }
  })();
  /// Set at turnEnded: the next agent/thought chunk opens a fresh block
  /// instead of merging into the closed turn's tail.
  private tailSealed = false;
  /// chunkBoundary sealed the current content-block run: the next
  /// chunk opens a fresh block (faithful stream order).
  private chunkSealed = false;
  togglePlanDock(): void {
    this.planDockOpen = !this.planDockOpen;
    // The user's click overrides the settle fold — they asked to see
    // (or hide) this panel; the next settle re-folds if it finishes
    // all-completed again.
    this.planSettledFold = false;
    // LOCAL-ONLY update: no revision bump. Folding used to re-render
    // the ENTIRE App (revision snapshot) — during a turn that means
    // contending with per-chunk renders, which is the reported fold
    // jank. PlanPanel subscribes to planDockOpen itself; App's
    // revision snapshot is unchanged so React bails out there.
    this.emit();
    // Persist to the HOST (NSUserDefaults): custom-scheme localStorage
    // dies with every page load — it kept resurrecting the panel the
    // user had folded. The local write stays as a same-load fallback.
    postToHost({ type: "planDockPref", open: this.planDockOpen });
    clearTimeout(this.planDockPersistTimer);
    this.planDockPersistTimer = setTimeout(() => {
      this.planDockPersistTimer = undefined;
      try { localStorage.setItem("goty.planDock.open", this.planDockOpen ? "1" : "0"); } catch { /* private mode */ }
    }, 250);
  }
  private planDockPersistTimer: number | undefined;
  hasOlder = false;
  /// Blocks the LAST transcriptPrepend added in front (consumed by the
  /// App to shift its render window + restore the viewport), and an
  /// epoch that ticks on EVERY prepend arrival (empty or not — the
  /// sentinel's in-flight guard releases on it).
  prependDelta = 0;
  prependEpoch = 0;
  loginProviders: Record<string, unknown>[] = [];
  configOptions: ConfigOption[] = [];
  commands: AgentCommand[] = [];
  /// Agent handshake phase: set on "starting", cleared by the first
  /// handshake-complete signal or a terminal error. The composer renders
  /// an explicit chip while this is non-null.
  starting: string | null = null;
  /// Transient system chatter (info notices: xd:// device mount lists).
  /// Auto-clears; a newer flash supersedes an older one's timer.
  flash: string | null = null;
  private flashSeq = 0;
  /// awaitingPermission — null when idle. `working` mirrors phase != null
  /// (kept as its own field: the composer's send/stop flip predates it).
  phase: "thinking" | "executing" | "awaitingPermission" | null = null;
  /// Current session's display name (Swift queries the adapter's
  /// session directory after handshake, history load, and each turn).
  sessionTitle: string | null = null;
  error: string | null = null;
  /// Auto-retry countdown (agent-reported backoff schedule): attempt
  /// N of M, ends at `endsAt` (ms epoch). Cleared when the turn
  /// resumes (chunks arrive), settles, or the user gets the failure.
  retry: { attempt: number; maxAttempts: number; endsAt: number;
           errorText: string | null } | null = null;
  /// The transport is down and Swift is riding the reconnect backoff.
  reconnecting = false;
  /// Turn wall-clock: `turnStartedAt` set when a turn starts
  /// (working:true), folded into `lastTurnMs` at turnEnded — the
  /// transcript tail shows the duration as the turn's closing stats.
  turnStartedAt: number | null = null;
  lastTurnMs: number | null = null;
  usage: { used?: number | null; size?: number | null;
           input?: number | null; output?: number | null;
           costAmount?: number | null; costCurrency?: string | null } | null = null;
  /// Composer statusbar: workspace/folder · branch (pushed by Swift).
  meta: { workspace: string | null; directory: string | null;
          branch: string | null; icon: string | null;
          capabilities: string[] } | null = null;
  /// Monotonic counter — the useSyncExternalStore snapshot. Status-only
  /// updates (tool upsert) change nothing else observable.
  revision = 0;
  /// Bumped whenever blocks are replaced wholesale (clearTranscript):
  /// the render window resets with it.
  generation = 0;
  /// Transport integrity accounting (cumulative across clearTranscript):
  /// the replayprobe asserts applied+rejected == what Swift delivered
  /// and rejected == 0 — a mismatch localizes the first lossy boundary.
  appliedCount = 0;
  rejectedCount = 0;
  private nextBlockId = 1;
  private listeners = new Set<Listener>();

  subscribe(fn: Listener) { this.listeners.add(fn); return () => { this.listeners.delete(fn); }; }
  private emit() { this.listeners.forEach((l) => l()); }

  /// Optimistic config pick (model / thinking …): the host confirms via
  /// a configOptions push, but that confirmation can land after the
  /// user's next interaction — without this the chip lags one pick
  /// behind. Truth resyncs on every configOptions push; a deferred or
  /// failed switch surfaces a notice from the host.
  pickConfigValue(configId: string, value: string): void {
    const opt = this.configOptions.find((o) => o.id === configId);
    if (!opt || opt.currentValue === value) return;
    opt.currentValue = value;
    this.revision += 1;
    this.emit();
  }

  /// Remove the oldest queued text matching `text` (the Swift outbox is
  /// the queue authority; its queueRemoved/queueDelivered events drive
  /// this mirror). Returns false when the row is already gone.
  private dequeue(text: string): boolean {
    const idx = this.pendingQueue.indexOf(text);
    if (idx < 0) return false;
    this.pendingQueue.splice(idx, 1);
    return true;
  }

  private push(block: BlockInput): Block {
    const stamped = { ...block, id: this.nextBlockId++ } as Block;
    this.blocks.push(stamped);
    return stamped;
  }

  /// agent/thought chunks append to the tail block of that kind while
  /// the stream continues it; a sealed boundary (turn end, message end,
  /// chunkBoundary) starts a fresh block. FAITHFUL DISPLAY CONTRACT
  /// the transcript mirrors the model's actual output structure. The
  /// wire's contentIndex (omp/pi-mono and claude stream-json both
  /// carry it) drives chunkBoundary upstream of here.
  private tail(kind: "agent" | "thought"): { kind: "agent" | "thought"; text: string } {
    const last = this.blocks[this.blocks.length - 1];
    if (last && last.kind === kind && !this.tailSealed && !this.chunkSealed) {
      const merged = { kind, id: last.id, text: last.text };
      this.blocks[this.blocks.length - 1] = merged;
      return merged;
    }
    this.tailSealed = false;
    this.chunkSealed = false;
    const block = this.push({ kind, text: "" }) as { kind: "agent" | "thought"; text: string };
    return block;
  }

  /// Same merge discipline as `tail`, for replayed user prompts
  /// (`user_message_chunk`): consecutive chunks fuse into one block.
  /// Empty chunks must not open a block — an empty user bubble renders
  /// as a stray gray bar at the transcript tail.
  private userTail(text: string): void {
    const last = this.blocks[this.blocks.length - 1];
    if (last && last.kind === "user") {
      this.blocks[this.blocks.length - 1] = { kind: "user" as const, id: last.id, text: last.text + text };
      return;
    }
    if (!text) return;
    this.push({ kind: "user", text });
  }
  /// Batch apply: parse and merge every event, then notify React ONCE.
  /// A replay burst is hundreds of events — per-event notification made
  /// React re-render the visible window after each one (the multi-second
  /// session/load stall).
  applyAll(rawList: unknown[]) {
    let applied = 0;
    let rejected = 0;
    let crashed = 0;
    for (const raw of rawList) {
      const event = parseEvent(raw);
      if (!event) { rejected += 1; continue; }
      // One poison event must not take the whole batch — a replay
      // burst is thousands of events — nor the pane (the boundary in
      // main.tsx catches what escapes here).
      try { this.applyParsed(event); applied += 1; }
      catch (err) { crashed += 1; console.error("goty: event crashed reducer", event.type, err); }
    }
    if (rejected > 0) {
      this.rejectedCount += rejected;
      console.warn("goty: rejected", rejected, "unparseable events in batch");
    }
    if (crashed > 0) this.rejectedCount += crashed;
    if (applied === 0) return;
    this.appliedCount += applied;
    this.revision += 1;
    this.emit();
  }
  apply(raw: unknown) {
    const event = parseEvent(raw);
    if (!event) { this.rejectedCount += 1; return; }
    this.applyParsed(event);
    this.appliedCount += 1;
    this.revision += 1;
    this.emit();
  }

  /// Post-crash blank slate (ErrorBoundary 重试): drop every VIEW
  /// structure; live pushes rebuild them. Transport accounting is
  /// cumulative by contract and stays.
  reset() {
    this.blocks = [];
    this.toolOrder = [];
    this.tools.clear();
    this.permission = null;
    this.plan = null;
    this.jobs = [];
    this.subagents = [];
    this.pendingQueue = [];
    this.hasOlder = false;
    this.error = null;
    this.tailSealed = false;
    this.chunkSealed = false;
    this.generation += 1;
    this.revision += 1;
    this.emit();
  }

  closeStats() {
    this.stats = null;
    this.revision += 1;
    this.emit();
  }
  private applyParsed(event: IncomingEvent) {
    // A terminal error ends startup too: a process that exited cannot
    // complete its handshake, and leaving `starting` set renders a
    // permanent contradictory spinner.
    if (STARTING_TERMINATORS[event.type]) this.starting = null;
    switch (event.type) {
      case "userMessage":
        // A settled plan hides HERE (not at the turn-end null): the
        // dock then unmounts while the user is looking at the composer,
        // never as a mid-read scroll jump.
        if (this.planCleared) { this.plan = null; this.planCleared = false; this.planSettledFold = false; }
        this.push({ kind: "user", text: event.text }); break;
      case "queueMessage": this.pendingQueue.push(event.text); break;
      // Outbox row actions (Swift-side), text-keyed so the mirror never
      // drifts; a missing text (already delivered) is a harmless no-op.
      case "queueRemoved": this.dequeue(event.text); break;
      case "queueDelivered":
        // The queued text leaves the dock and lands in the transcript:
        // the host sends it through send()/steer() as it pushes this,
        // so the block IS the delivery echo. It opens a turn like
        // userMessage does — fold a settled plan here too.
        this.dequeue(event.text);
        if (this.planCleared) { this.plan = null; this.planCleared = false; this.planSettledFold = false; }
        this.push({ kind: "user", text: event.text });
        break;
      case "userChunk":
        this.userTail(event.text);
        this.retry = null;   // live user-side echo — the turn is streaming
        break;
      case "agentChunk":
        if (event.text) this.tail("agent").text += event.text;
        // A chunk after a retry schedule means the retried call is
        // streaming — the countdown is over.
        this.retry = null;
        break;
      case "chunkBoundary":
        // The model switched content blocks: seal the current run so
        // the NEXT chunk opens a fresh block below, in true stream
        // order. No same-kind merging across the boundary.
        this.chunkSealed = true; break;
      case "historyTruncated":
        this.hasOlder = event.truncated; break;
      case "transcriptPrepend": {
        // Older history lands in FRONT. Assembly stays correct by
        // construction: the events rebuild through the SAME pipeline
        // into a fresh prefix (their tail ends on a turn boundary, so
        // no fusion across the seam), then the current blocks append
        // unchanged — ids keep their identity and the DOM keeps the
        // existing nodes.
        const savedBlocks = this.blocks;
        const savedTools = new Map(this.tools);
        const savedOrder = this.toolOrder;
        this.blocks = [];
        this.toolOrder = [];
        this.tools.clear();
        this.tailSealed = false;
        this.chunkSealed = false;
        for (const raw of event.events) {
          const parsed = IncomingEventSchema.safeParse(raw);
          if (parsed.success) this.applyParsed(parsed.data);
        }
        if (this.blocks.length > 0) {
          // The prefix's own tail stays sealed: nothing may merge into
          // it from the head side either.
          this.tailSealed = true;
          this.blocks = [...this.blocks, ...savedBlocks];
        } else {
          this.blocks = savedBlocks;
        }
        for (const [id, call] of savedTools) this.tools.set(id, call);
        this.toolOrder = [...this.toolOrder, ...savedOrder];
        this.prependDelta = this.blocks.length - savedBlocks.length;
        this.prependEpoch += 1;
        this.hasOlder = false;
        break;
      }
      case "thoughtChunk":
        if (event.text) this.tail("thought").text += event.text;
        // The retried call is streaming its THINKING — the backoff is
        // over even though no text chunk has landed yet (the "streaming
        // thoughts under a live 等待响应 banner" zombie, 2026-09-10).
        this.retry = null;
        break;
      case "toolCall": {
        // tool_call_update omits title/kind/rawInput — merge over the
        // initial tool_call instead of clobbering them with null.
        // A tool moving also proves the retried call resolved (backoff
        // runs no tools) — same zombie clear as the chunk cases.
        this.retry = null;
        const prev = this.tools.get(event.id);
        const call: ToolCall = {
          id: event.id,
          title: event.title ?? prev?.title,
          kind: event.kind ?? prev?.kind,
          status: event.status ?? prev?.status,
          content: (event.content ?? []).length > 0 ? (event.content as ToolContent[]) : prev?.content ?? [],
          output: (event.output ?? []).length > 0 ? (event.output as ToolContent[]) : prev?.output ?? [],
          rawInput: event.rawInput ?? prev?.rawInput ?? null,
          oldText: event.oldText ?? prev?.oldText ?? null,
        };
        if (!this.tools.has(event.id)) {
          this.toolOrder.push(event.id);
          this.push({ kind: "tool", call });
        } else {
          // Swap the owning block's `call` too: BlockView is memoized on
          // block/call identity — updating only the tools Map left the
          // card frozen at its mount-time status (运行中) until a click
          // re-rendered it and revealed 完成.
          for (let i = this.blocks.length - 1; i >= 0; i--) {
            const b = this.blocks[i];
            if (b.kind === "tool" && b.call.id === event.id) {
              this.blocks[i] = { ...b, call };
              break;
            }
          }
        }
        this.tools.set(event.id, call);
        break;
      }
      case "plan":
        // An EMPTY plan (turn settled) does not clear the dock: plan
        // lives BELOW a bottom-pinned transcript, and unmounting it
        // grows the viewport mid-read — the browser clamps scrollTop
        // and the whole conversation jumps up by the dock's height
        // (the turn-end flash + scroll jump, reported many times).
        // The last plan stays visible; it hides when the next turn
        // starts (planCleared → userMessage/queueDelivered).
        if ((event.entries ?? []).length > 0) {
          // A snapshot identical to the one already showing carries no
          // new information — and omp's get_state keeps serving the LAST
          // all-completed todoPhases forever after settle (the session
          // model only resets on /new or a fresh plan; the TUI's
          // tasks.todoClearDelay timer clears a view-local copy the RPC
          // never sees). Without this guard the 2s poll would resurrect
          // the plan the turn-end handler just retired, and the dock
          // would pin a finished 10/10 plan indefinitely. A CHANGED
          // snapshot (the agent rewrote the plan) still lands.
          if (this.planCleared && this.plan != null
              && planEntriesEqual(this.plan.entries, event.entries as PlanEntry[])) {
            break;
          }
          this.plan = { entries: event.entries as PlanEntry[] };
          // An all-completed snapshot while the agent is IDLE is by
          // definition settled — arm the retirement and present folded
          // right here, not only via turnEnded: after a webview reload
          // no turnEnded ever comes, and the replayed stale snapshot
          // would reopen the finished panel (2026-09-14 report). While
          // the agent is WORKING the panel stays open for progress.
          const settled = !this.working
              && (event.entries as PlanEntry[]).every((e) => e.status === "completed");
          this.planCleared = settled;
          this.planSettledFold = settled;
        } else {
          this.planCleared = this.plan != null;
        }
        break;
      case "planDockPref":
        // Host truth (page-ready push or echo of our own toggle):
        // same LOCAL-only semantics as togglePlanDock — no revision
        // bump, the panel's own subscription repaints.
        this.planDockOpen = event.open;
        this.emit();
        break;
      case "permission": this.permission = event; break;
      case "permissionResolved":
        // Agent-side cancel targets one request; the no-id variant
        // (host ack after our own answer) clears whatever is showing.
        this.permission = (!event.requestID
          || this.permission?.requestID === event.requestID)
          ? null : this.permission;
        break;
      case "branchState": this.branchBusy = event.active; break;
      case "turnEnded": {
        // Settled-turn stats land IN the transcript, glued to the turn
        // they close — the next user message must append BELOW them,
        // not sandwich them at the composer (2026-08-31). Duration is
        // PER-TURN (a stale lastTurnMs used to replay the previous
        // turn's time on a bare turnEnded), and the line needs at
        // least one meaningful part — a sub-100ms turn with no token
        // counts is pure noise next to the "压缩中…" chip.
        const ms = this.turnStartedAt != null ? Date.now() - this.turnStartedAt : null;
        this.turnStartedAt = null;
        const u = this.usage;
        const parts: string[] = [];
        if (ms != null && ms >= 100) parts.push(`⏱ ${(ms / 1000).toFixed(1)}s`);
        if (u?.input != null) parts.push(`↑${fmtTokens(u.input)}`);
        if (u?.output != null) parts.push(`↓${fmtTokens(u.output)}`);
        if (u?.costAmount != null) {
          parts.push(`$${u.costAmount < 1 ? u.costAmount.toFixed(4) : u.costAmount.toFixed(2)}`);
        }
        if (parts.length > 0) this.push({ kind: "turnStats", text: parts.join(" · ") });
        // Turn boundary SEAL: the next turn's text must never merge
        // into this turn's tail block (tail() only breaks on intervening
        // blocks; a turn can end with none pushed).
        this.tailSealed = true;
        // Queued follow-ups NO LONGER flush here: the pane owns the
        // outbox and delivers strictly one per turnEnded via
        // queueDelivered (true processing order, one block per settle).
        this.retry = null;
        // A fully-completed plan retires with the turn: keep the data
        // (the dock stays mounted — no mid-read scroll jump) but arm
        // planCleared so the next user block unmounts it, and FOLD the
        // panel now (planSettledFold — the finished plan reappearing
        // open was the 2026-09-14 irritation report). omp never clears
        // its todoPhases on settle (see the plan handler); adapters
        // that DO send an empty plan arm the same flag through that
        // path.
        if (this.plan != null && this.plan.entries.length > 0
            && this.plan.entries.every((e) => e.status === "completed")) {
          this.planCleared = true;
          this.planSettledFold = true;
        }
        break;
      }
      case "sessions": this.sessions = coerceList(event.sessions, AgentSessionSummarySchema); break;
      case "working":
        this.working = event.value;
        if (event.value) {
          this.error = null;
          if (this.turnStartedAt == null) this.turnStartedAt = Date.now();
        } else {
          this.phase = null;
          this.retry = null;
        }
        break;
      case "phase":
        this.phase = (event.value === "thinking" || event.value === "executing"
          || event.value === "awaitingPermission") ? event.value : null;
        if (this.phase) this.error = null;
        break;
      case "error":
        // Error is terminal for this pane's current lifecycle. Clear every
        // transient status so the failure and its retry action replace, not
        // stack under, the old startup/working indicators.
        this.starting = null;
        this.working = false;
        this.phase = null;
        this.reconnecting = false;
        this.retry = null;
        this.error = event.text;
        // TUI parity: the failure also lands as a transcript line so a
        // reopened pane still shows what happened.
        this.push({ kind: "error", text: event.text });
        break;
      case "retryScheduled":
        // The agent is backing off before retrying a provider failure —
        // the composer swaps its working spinner for a live countdown.
        this.retry = {
          attempt: event.attempt ?? 0,
          maxAttempts: event.maxAttempts ?? 0,
          endsAt: Date.now() + (event.delayMs ?? 0),
          errorText: event.errorText ?? null,
        };
        break;
      case "sessionTitle": this.sessionTitle = event.title ?? null; break;
      case "reconnecting":
        this.reconnecting = event.value;
        if (event.value) this.error = null;
        break;
      case "theme": {
        const root = document.documentElement;
        for (const [k, v] of Object.entries(event.vars)) {
          if (k === "mode") root.dataset.theme = v;
          else root.style.setProperty(`--${k}`, v);
        }
        break;
      }
      case "starting": this.starting = event.agent; break;
      case "ready":
        // Handshake complete — pure state (the STARTING_TERMINATORS
        // lookup already cleared `starting`); never transcript content.
        break;
      case "status":
        // Agent notices (extension setStatus, command_output…): transcript
        // lines, not a hidden field — /compact's "Compaction failed: …"
        // used to vanish here with no reader.
        if (event.text) this.push({ kind: "notice", text: event.text });
        break;
      case "statusFlash": {
        // Transient system chatter (xd:// device mount lists on model
        // switches): flash briefly, never park in the transcript. A
        // newer flash supersedes the older one's clear timer.
        this.flash = event.text;
        const seq = ++this.flashSeq;
        setTimeout(() => {
          if (this.flashSeq !== seq) return;
          this.flash = null;
          this.revision += 1;
          this.emit();
        }, 6000);
        break;
      }
      case "configOptions": {
        // One knob per id — a double-emitting adapter must not render
        // two chips (and two popovers) for the same knob. Last wins:
        // the fresher entry carries the newer currentValue.
        const seen = new Map<string, ConfigOption>();
        for (const opt of coerceList(event.options, ConfigOptionSchema)) {
          seen.set(opt.id, opt);
        }
        this.configOptions = [...seen.values()];
        break;
      }
      case "commands": this.commands = coerceList(event.commands, AgentCommandSchema); break;
      case "usage": this.usage = event; break;
      case "clearTranscript":
        this.blocks = []; this.toolOrder = []; this.tools.clear();
        this.permission = null; this.working = false;
        this.phase = null; this.error = null; this.reconnecting = false;
        this.retry = null;
        this.turnStartedAt = null;
        this.pendingQueue = []; this.tailSealed = false; this.chunkSealed = false;
        this.hasOlder = false;
        this.plan = null; this.jobs = []; this.subagents = [];
        this.generation += 1;
        break;
      case "runtimeStatus": {
        const next: RuntimeState = {
          fastEnabled: event.fastEnabled ?? null,
          fastActive: event.fastActive ?? null,
          contextTokens: event.contextTokens ?? null,
          contextWindow: event.contextWindow ?? null,
          tokensPerSecond: event.tokensPerSecond ?? null,
          queued: event.queued ?? null,
          compacting: event.compacting ?? null,
          streaming: event.streaming ?? null,
        };
        if (JSON.stringify(next) !== JSON.stringify(this.runtime)) {
          this.runtime = next;
        }
        break;
      }
      case "jobs": {
        const rows = (event.jobs ?? []) as JobRow[];
        const key = rows.map((j) => `${j.id}:${j.status}:${j.startTime ?? 0}`).join("|");
        const prevKey = this.jobs.map((j) => `${j.id}:${j.status}:${j.startTime ?? 0}`).join("|");
        if (key !== prevKey) {
          this.jobs = rows;
        }
        break;
      }
      case "subagent": {
        const row: SubagentRow = { id: event.id, state: event.state ?? null,
          detail: event.detail ?? null, at: Date.now() };
        const idx = this.subagents.findIndex((s) => s.id === row.id);
        if (idx >= 0) {
          this.subagents[idx] = { ...this.subagents[idx], ...row,
            state: row.state ?? this.subagents[idx].state,
            detail: row.detail ?? this.subagents[idx].detail };
        } else {
          this.subagents.push(row);
        }
        break;
      }
      case "entryMark": {
        const kind = event.role === "user" ? "user" : "agent";
        // Stamp the NEWEST still-unmarked block of the role. Live
        // turns learn their entry ids late (a store read ~1.5s after
        // settle, newest-first — the live wire never carries them),
        // so a delayed mark must skip blocks that already have one.
        // A mark whose id already landed is surplus (replay overlap,
        // windowed-out block): no-op, never re-stamp a second block.
        if (this.blocks.some(b => b.kind === kind && b.entryId === event.entryId)) {
          break;
        }
        for (let i = this.blocks.length - 1; i >= 0; i--) {
          const b = this.blocks[i];
          if (b.kind !== kind || b.entryId) continue;
          this.blocks[i] = { ...b, entryId: event.entryId } as typeof b;
          break;
        }
        break;
      }
      case "stats": this.stats = event.stats; break;
      case "loginProviders": this.loginProviders = event.providers; break;
      case "openURL": break;   // host-consumed (login browser hop)
      case "files": this.files = event.files; break;
      case "meta":
        this.meta = { workspace: event.workspace ?? null,
                      directory: event.directory ?? null,
                      branch: event.branch ?? null, icon: event.icon ?? null,
                      capabilities: event.capabilities ?? [] };
        break;
      default: {
        // Exhaustiveness guard: a swallowed case (an edit once ate
        // userMessage — sent messages vanished from the transcript)
        // must fail the BUILD, not ship silently.
        const exhaustive: never = event;
        void exhaustive;
      }
    }
  }

}

export const store = new Store();

// Debug/testing handle: perf probes and the e2e harness read block state directly.
if (typeof window !== "undefined") {
  (window as unknown as { __gotyStore: Store }).__gotyStore = store;
}

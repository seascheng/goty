import { z } from "zod";

/// Swift → JS events (AgentWebBridge). Schema-parsed once at this
/// boundary; Swift fills absent optionals with NSNull(), so absent string
/// fields arrive as `null` and stay nullable through the view layer.
export type ToolContent = { type: string; text?: string | null; path?: string | null };
export type ToolCall = {
  id: string; title?: string | null; kind?: string | null; status?: string | null;
  content: ToolContent[];
  rawInput?: Record<string, unknown> | null;
  oldText?: string | null;
};
export type PlanEntry = { content: string; priority?: string | null; status?: string | null };
export type Permission = {
  requestID: number; toolCallTitle?: string | null;
  options: { optionId: string; name: string; kind?: string | null }[];
};
type DistributiveOmit<T, K extends PropertyKey> = T extends unknown ? Omit<T, K> : never;
/// A block before it gets its stable identity stamp.
type BlockInput = DistributiveOmit<Block, "id">;

export type Block =
  | { kind: "user"; id: number; text: string }
  | { kind: "agent"; id: number; text: string }
  | { kind: "thought"; id: number; text: string }
  | { kind: "tool"; id: number; call: ToolCall }
  | { kind: "plan"; id: number; entries: PlanEntry[] };

const ToolContentSchema = z.object({
  type: z.string(),
  text: z.string().nullish(),
  path: z.string().nullish(),
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

const IncomingEventSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("userMessage"), text: z.string() }),
  z.object({ type: z.literal("userChunk"), text: z.string() }),
  z.object({ type: z.literal("agentChunk"), text: z.string() }),
  z.object({ type: z.literal("thoughtChunk"), text: z.string() }),
  z.object({
    type: z.literal("toolCall"),
    id: z.string(),
    title: z.string().nullish(),
    kind: z.string().nullish(),
    status: z.string().nullish(),
    content: z.array(ToolContentSchema).nullish(),
    rawInput: z.record(z.string(), z.unknown()).nullish(),
    oldText: z.string().nullish(),
  }),
  z.object({ type: z.literal("plan"), entries: z.array(PlanEntrySchema).nullish() }),
  z.object({
    type: z.literal("permission"),
    requestID: z.number(),
    toolCallTitle: z.string().nullish(),
    options: z.array(PermissionOptionSchema),
  }),
  z.object({ type: z.literal("permissionResolved") }),
  z.object({ type: z.literal("turnEnded") }),
  z.object({ type: z.literal("working"), value: z.boolean() }),
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
  z.object({ type: z.literal("theme"), vars: z.record(z.string(), z.string()) }),
  z.object({
    type: z.literal("meta"),
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

class Store {
  blocks: Block[] = [];
  toolOrder: string[] = [];
  sessions: AgentSessionSummary[] = [];
  tools = new Map<string, ToolCall>();
  files: string[] = [];
  permission: Permission | null = null;
  working = false;
  configOptions: ConfigOption[] = [];
  commands: AgentCommand[] = [];
  usage: { used?: number | null; size?: number | null;
           input?: number | null; output?: number | null;
           costAmount?: number | null; costCurrency?: string | null } | null = null;
  status = "连接中…";
  /// Composer statusbar: workspace/folder · branch (pushed by Swift).
  meta: { workspace: string | null; directory: string | null;
          branch: string | null; icon: string | null } | null = null;
  /// Monotonic counter — the useSyncExternalStore snapshot. Status-only
  /// updates (tool upsert) change nothing else observable.
  revision = 0;
  /// Bumped whenever blocks are replaced wholesale (clearTranscript):
  /// the render window resets with it.
  generation = 0;
  private nextBlockId = 1;
  private listeners = new Set<Listener>();

  subscribe(fn: Listener) { this.listeners.add(fn); return () => { this.listeners.delete(fn); }; }
  private emit() { this.listeners.forEach((l) => l()); }

  private push(block: BlockInput): Block {
    const stamped = { ...block, id: this.nextBlockId++ } as Block;
    this.blocks.push(stamped);
    return stamped;
  }

  /// agent/thought chunks append to the LAST block of that kind; a closed
  /// turn (turnEnded/userMessage/tool in between) starts a fresh block.
  /// The merged block is replaced (not mutated) so memoized rows keyed by
  /// stable ids re-render only the tail.
  private tail(kind: "agent" | "thought"): { kind: "agent" | "thought"; text: string } {
    const last = this.blocks[this.blocks.length - 1];
    if (last && last.kind === kind) {
      const merged = { kind, id: last.id, text: last.text };
      this.blocks[this.blocks.length - 1] = merged;
      return merged;
    }
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
  apply(raw: unknown) {
    const event = parseEvent(raw);
    if (!event) return;
    switch (event.type) {
      case "userMessage": this.push({ kind: "user", text: event.text }); break;
      case "userChunk":
        this.userTail(event.text); break;
      case "agentChunk":
        if (event.text) this.tail("agent").text += event.text; break;
      case "thoughtChunk":
        if (event.text) this.tail("thought").text += event.text; break;
      case "toolCall": {
        // tool_call_update omits title/kind/rawInput — merge over the
        // initial tool_call instead of clobbering them with null.
        const prev = this.tools.get(event.id);
        const call: ToolCall = {
          id: event.id,
          title: event.title ?? prev?.title,
          kind: event.kind ?? prev?.kind,
          status: event.status ?? prev?.status,
          content: (event.content ?? []).length > 0 ? (event.content as ToolContent[]) : prev?.content ?? [],
          rawInput: event.rawInput ?? prev?.rawInput ?? null,
          oldText: event.oldText ?? prev?.oldText ?? null,
        };
        if (!this.tools.has(event.id)) {
          this.toolOrder.push(event.id);
          this.push({ kind: "tool", call });
        }
        this.tools.set(event.id, call);
        break;
      }
      case "plan": this.push({ kind: "plan", entries: event.entries ?? [] }); break;
      case "permission": this.permission = event; break;
      case "permissionResolved": this.permission = null; break;
      case "turnEnded": this.push({ kind: "agent", text: "" }); this.working = false; break;
      case "sessions": this.sessions = coerceList(event.sessions, AgentSessionSummarySchema); break;
      case "working": this.working = event.value; break;
      case "status": this.status = event.text; break;
      case "configOptions": this.configOptions = coerceList(event.options, ConfigOptionSchema); break;
      case "commands": this.commands = coerceList(event.commands, AgentCommandSchema); break;
      case "usage": this.usage = event; break;
      case "clearTranscript":
        this.blocks = []; this.toolOrder = []; this.tools.clear();
        this.permission = null; this.working = false;
        this.generation += 1;
        break;
      case "files": this.files = event.files; break;
      case "meta":
        this.meta = { workspace: event.workspace ?? null,
                      directory: event.directory ?? null,
                      branch: event.branch ?? null, icon: event.icon ?? null };
        break;
      case "theme": {
        const root = document.documentElement;
        for (const [k, v] of Object.entries(event.vars)) {
          if (k === "mode") root.dataset.theme = v;
          else root.style.setProperty(`--${k}`, v);
        }
        break;
      }
    }
    this.revision += 1;
    this.emit();
  }

}

export const store = new Store();

// Debug/testing handle: perf probes and the e2e harness read block state directly.
if (typeof window !== "undefined") {
  (window as unknown as { __gotyStore: Store }).__gotyStore = store;
}

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
export type Block =
  | { kind: "user"; text: string }
  | { kind: "agent"; text: string }
  | { kind: "thought"; text: string }
  | { kind: "tool"; call: ToolCall }
  | { kind: "plan"; entries: PlanEntry[] };

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
  z.object({ type: z.literal("configOptions"), options: z.array(ConfigOptionSchema) }),
  z.object({ type: z.literal("commands"), commands: z.array(AgentCommandSchema) }),
  z.object({
    type: z.literal("usage"),
    used: z.number().nullish(),
    size: z.number().nullish(),
    costAmount: z.number().nullish(),
    costCurrency: z.string().nullish(),
  }),
]);

export type IncomingEvent = z.infer<typeof IncomingEventSchema>;

type Listener = () => void;

function parseEvent(raw: unknown): IncomingEvent | null {
  const result = IncomingEventSchema.safeParse(raw);
  return result.success ? result.data : null;
}

class Store {
  blocks: Block[] = [];
  toolOrder: string[] = [];
  tools = new Map<string, ToolCall>();
  permission: Permission | null = null;
  working = false;
  configOptions: ConfigOption[] = [];
  commands: AgentCommand[] = [];
  usage: { used?: number | null; size?: number | null;
           costAmount?: number | null; costCurrency?: string | null } | null = null;
  status = "连接中…";
  /// Monotonic counter — the useSyncExternalStore snapshot. Status-only
  /// updates (tool upsert) change nothing else observable.
  revision = 0;
  private listeners = new Set<Listener>();

  subscribe(fn: Listener) { this.listeners.add(fn); return () => { this.listeners.delete(fn); }; }
  private emit() { this.listeners.forEach((l) => l()); }

  apply(raw: unknown) {
    const event = parseEvent(raw);
    if (!event) return;
    switch (event.type) {
      case "userMessage": this.blocks.push({ kind: "user", text: event.text }); break;
      case "agentChunk":
        this.tail("agent").text += event.text; break;
      case "thoughtChunk":
        this.tail("thought").text += event.text; break;
      case "toolCall": {
        const call: ToolCall = { id: event.id, title: event.title,
                                 kind: event.kind, status: event.status,
                                 content: event.content ?? [],
                                 rawInput: event.rawInput, oldText: event.oldText };
        if (!this.tools.has(event.id)) {
          this.toolOrder.push(event.id);
          this.blocks.push({ kind: "tool", call });
        }
        this.tools.set(event.id, call);
        break;
      }
      case "plan": this.blocks.push({ kind: "plan", entries: event.entries ?? [] }); break;
      case "permission": this.permission = event; break;
      case "permissionResolved": this.permission = null; break;
      case "turnEnded": this.blocks.push({ kind: "agent", text: "" }); this.working = false; break;
      case "working": this.working = event.value; break;
      case "status": this.status = event.text; break;
      case "configOptions": this.configOptions = event.options; break;
      case "commands": this.commands = event.commands; break;
      case "usage": this.usage = event; break;
    }
    this.revision += 1;
    this.emit();
  }

  /// agent/thought chunks append to the LAST block of that kind; a closed
  /// turn (turnEnded/userMessage/tool in between) starts a fresh block.
  private tail(kind: "agent" | "thought"): { kind: "agent" | "thought"; text: string } {
    const last = this.blocks[this.blocks.length - 1];
    if (last && last.kind === kind) return last;
    const block = { kind, text: "" };
    this.blocks.push(block);
    return block;
  }
}

export const store = new Store();

import { z } from "zod";

/// Swift → JS events (AgentWebBridge.push). Schema-parsed once at this
/// boundary; Swift fills absent optionals with NSNull(), so absent string
/// fields arrive as `null` and stay nullable through the view layer.
export type ToolContent = { type: string; text?: string | null; path?: string | null };
export type ToolCall = {
  id: string; title?: string | null; kind?: string | null; status?: string | null;
  content: ToolContent[];
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
  z.object({ type: z.literal("theme"), vars: z.record(z.string(), z.string()) }),
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
      case "theme":
        for (const [key, value] of Object.entries(event.vars)) {
          document.documentElement.style.setProperty(key, value);
        }
        return;
      case "userMessage": this.blocks.push({ kind: "user", text: event.text }); break;
      case "agentChunk":
        this.tail("agent").text += event.text; break;
      case "thoughtChunk":
        this.tail("thought").text += event.text; break;
      case "toolCall": {
        const call: ToolCall = { id: event.id, title: event.title,
                                 kind: event.kind, status: event.status,
                                 content: event.content ?? [] };
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
      case "turnEnded": this.blocks.push({ kind: "agent", text: "" }); break;
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

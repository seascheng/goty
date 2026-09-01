// goty — see CLAUDE.md for the working principles.
// Loaded by omp/pi's own extension loader (their public extension API).
// Reports the agent's live TUI state + background-job snapshot to the
// goty-sessiond that owns the pane: one JSON line
// {"pane","state","seq","jobs"?} on the daemon's unix socket; any reply
// byte closes the connection.

import net from "node:net";

type AgentState = "working" | "blocked" | "idle";

interface JobSnapshot {
  id: string;
  type: string;
  status: string;
  label: string;
  startTime: number;
  agentId?: string;
}

interface Report {
  pane: string;
  state: AgentState;
  seq: number;
  jobs?: JobSnapshot[];
}

/** The slice of omp/pi's extension API this file consumes. */
interface PiExtensionHost {
  on(event: "agent_start", handler: (event: unknown, ctx: PiContext) => void): void;
  on(event: "agent_end", handler: (event: unknown, ctx: PiContext) => void): void;
  on(event: "tool_approval_requested", handler: (event: unknown, ctx: PiContext) => void): void;
  on(event: "tool_approval_resolved", handler: (event: unknown, ctx: PiContext) => void): void;
  on(event: "session_start", handler: (event: unknown, ctx: PiContext) => void): void;
}

/** ctx.getAsyncJobSnapshot + managed timers (extensions.md contract). */
interface PiContext {
  getAsyncJobSnapshot(): { running: JobSnapshot[] } | null;
  setInterval(fn: () => void, ms: number): unknown;
}

const socketPath = process.env.GOTY_GUI_SOCKET_PATH;
const paneId = process.env.GOTY_GUI_PANE_ID;

function report(state: AgentState, jobs: JobSnapshot[] | undefined) {
  if (!socketPath || !paneId) {
    return;
  }
  const payload: Report = { pane: paneId, state, seq: Date.now() * 1000 };
  if (jobs) {
    payload.jobs = jobs;
  }
  const socket = net.createConnection(socketPath);
  const finish = () => socket.destroy();
  socket.on("error", finish);
  socket.on("connect", () => socket.write(JSON.stringify(payload) + "\n"));
  socket.on("data", finish);
  const timeout = setTimeout(finish, 500);
  timeout.unref?.();
}

/// Undefined ctx (older runtime) or a throwing snapshot: omit the jobs
/// field instead of failing the whole state report.
function runningJobs(ctx: PiContext | undefined): JobSnapshot[] | undefined {
  if (!ctx) {
    return undefined;
  }
  try {
    return ctx.getAsyncJobSnapshot()?.running ?? [];
  } catch {
    return undefined;
  }
}

export default function gotyGuiAgentState(pi: PiExtensionHost) {
  if (!socketPath || !paneId) {
    return;
  }
  let agentActive = false;
  let blocked = 0;
  let idleTimer: NodeJS.Timeout | undefined;

  const state = (): AgentState =>
    blocked > 0 ? "blocked" : agentActive ? "working" : "idle";

  // Job rows re-report only on membership/status change; elapsed time
  // is computed GUI-side from startTime — a per-second report of an
  // unchanged set would be pure socket noise.
  let lastJobsKey = "";
  const jobsKey = (jobs: JobSnapshot[]) =>
    jobs.map((j) => `${j.id}:${j.status}:${j.label}:${j.startTime}`).join("|");

  const publish = (ctx?: PiContext) => report(state(), runningJobs(ctx));

  const pollJobs = (ctx: PiContext) => {
    let jobs: JobSnapshot[];
    try {
      jobs = ctx.getAsyncJobSnapshot()?.running ?? [];
    } catch {
      return;
    }
    const key = jobsKey(jobs);
    if (key === lastJobsKey) {
      return;
    }
    lastJobsKey = key;
    report(state(), jobs);
  };

  // Managed timer: the runtime clears it on session_shutdown and
  // contains a throwing callback (extensions.md background work).
  pi.on("session_start", (_event, ctx) => {
    try {
      ctx.setInterval(() => pollJobs(ctx), 1000);
    } catch {
      // timers unavailable on this runtime — event publishes still carry jobs
    }
  });

  pi.on("agent_start", (_event, ctx) => {
    clearTimeout(idleTimer);
    agentActive = true;
    publish(ctx);
  });

  pi.on("agent_end", (_event, ctx) => {
    agentActive = false;
    clearTimeout(idleTimer);
    // Debounce: streaming turns can end one message and immediately
    // start the next; an instant idle flash between them is noise.
    idleTimer = setTimeout(() => publish(ctx), 250);
    idleTimer.unref?.();
  });

  pi.on("tool_approval_requested", (_event, ctx) => {
    blocked += 1;
    publish(ctx);
  });

  pi.on("tool_approval_resolved", (_event, ctx) => {
    blocked = Math.max(0, blocked - 1);
    publish(ctx);
  });
}

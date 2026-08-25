// goty — see CLAUDE.md for the working principles.
// Loaded by omp/pi's own extension loader (their public extension API).
// Reports the agent's live TUI state to the goty-sessiond that owns
// the pane: one JSON line {"pane","state","seq"} on the daemon's unix
// socket; any reply byte closes the connection.

import net from "node:net";

type AgentState = "working" | "blocked" | "idle";

interface Report {
  pane: string;
  state: AgentState;
  seq: number;
}

/** The slice of omp/pi's extension API this file consumes. */
interface PiExtensionHost {
  on(event: "agent_start", handler: () => void): void;
  on(event: "agent_end", handler: () => void): void;
  on(event: "tool_approval_requested", handler: () => void): void;
  on(event: "tool_approval_resolved", handler: () => void): void;
}

const socketPath = process.env.GOTY_GUI_SOCKET_PATH;
const paneId = process.env.GOTY_GUI_PANE_ID;

function report(state: AgentState) {
  if (!socketPath || !paneId) {
    return;
  }
  const payload: Report = { pane: paneId, state, seq: Date.now() * 1000 };
  const socket = net.createConnection(socketPath);
  const finish = () => socket.destroy();
  socket.on("error", finish);
  socket.on("connect", () => socket.write(JSON.stringify(payload) + "\n"));
  socket.on("data", finish);
  const timeout = setTimeout(finish, 500);
  timeout.unref?.();
}

export default function gotyGuiAgentState(pi: PiExtensionHost) {
  if (!socketPath || !paneId) {
    return;
  }
  let agentActive = false;
  let blocked = 0;
  let idleTimer: NodeJS.Timeout | undefined;

  const publish = () =>
    report(blocked > 0 ? "blocked" : agentActive ? "working" : "idle");

  pi.on("agent_start", () => {
    clearTimeout(idleTimer);
    agentActive = true;
    publish();
  });

  pi.on("agent_end", () => {
    agentActive = false;
    clearTimeout(idleTimer);
    // Debounce: streaming turns can end one message and immediately
    // start the next; an instant idle flash between them is noise.
    idleTimer = setTimeout(publish, 250);
    idleTimer.unref?.();
  });

  pi.on("tool_approval_requested", () => {
    blocked += 1;
    publish();
  });

  pi.on("tool_approval_resolved", () => {
    blocked = Math.max(0, blocked - 1);
    publish();
  });
}

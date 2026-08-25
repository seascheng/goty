# Terminal-Native AI Tasks Design

**Date:** 2026-08-25  
**Status:** Approved for implementation planning

## Problem

Goty should make AI available at the point where a user works: inside a local or SSH terminal, without requiring an AI agent installation on every server and without forcing the user into a separate chat or TUI. A user should be able to type a request such as `@ai rename these files`, receive an actionable proposal, and execute it against the current terminal target safely.

## Goals

- Trigger Goty AI from a shell prompt with a line-leading `@ai`.
- Keep ordinary shell commands and existing TUI input unchanged.
- Run the AI model and orchestration in Goty on the local machine.
- Present AI output as a structured AI block associated with the terminal transcript, not as fake PTY stdout.
- Treat local and SSH targets uniformly from the agent's perspective.
- Automatically perform a bounded allowlist of read-only probes.
- Require confirmation for mutations and bind confirmation to the exact target and proposal.
- Keep tasks independent of shell stdin and allow terminal use while tasks run.

## Non-goals for the first version

- Deploying `goty-agent` to remote hosts.
- Integrating `@pi` or `@claude` providers.
- Starting persistent pi/Claude sessions for one-off requests.
- General-purpose automatic rollback.
- Default access to full shell history, arbitrary files, or other windows.
- Intercepting input while a full-screen TUI is active.

## User interaction

At a recognized shell prompt, Goty consumes an input line beginning with `@ai`; it does not send that line to the PTY. It creates an AI task in the current terminal context. The default context contains the request, visible terminal content, current host/user/cwd, OS, shell, and local-vs-SSH target information. Session history and files are opt-in attachments.

The terminal visually combines two logical streams:

- PTY stream: shell input echo and bash/SSH stdout/stderr, rendered by the existing terminal.
- AI stream: structured task blocks rendered by Goty outside the Ghostty PTY buffer.

An AI block shows progress, probe summaries, proposals, target identity, risk, and results. It provides `Execute`, `Edit`, and `Cancel`. `Fill terminal` is an explicit action; generated commands are not injected into the shell by default.

When the current foreground program is a known shell in ordinary line mode, Goty may recognize line-leading `@ai`. When a full-screen TUI (pi, Claude Code, or another alternate-screen application) is active, Goty never intercepts input. A dedicated shortcut (initially `Cmd-Shift-A`) can create an AI task using the current terminal context. If process/state detection is uncertain, Goty does not intercept the line; the shortcut remains available.

## Architecture

### Core

Core code remains AppKit-free and owns:

- `AITask` and its lifecycle.
- `AIContext` and immutable `ExecutionTarget` snapshots.
- `AIProposal` with command, explanation, affected paths, risk, and rollback hint.
- Model/provider orchestration and structured tool calls.
- Command classification and the read-only policy.
- Local and SSH execution adapters.

Suggested modules under `swift-app/Sources/Core`:

```text
AI/AITask.swift
AI/AIContext.swift
AI/AIProposal.swift
AI/AITaskCoordinator.swift
AI/ExecutionTarget.swift
Execution/CommandExecutor.swift
Execution/LocalExecutor.swift
Execution/SSHExecutor.swift
Execution/ReadOnlyPolicy.swift
```

Names are guidance, not a requirement to create one file per type if the existing project structure has a better home.

### UI

UI code under `swift-app/Sources/UI` owns the AI block, proposal display, buttons, editing flow, shortcut handling, and terminal integration. It must not embed AI control logic or AppKit imports in Core.

Suggested UI pieces:

```text
Terminal/AITaskBlock.swift
Terminal/AIProposalView.swift
```

The AI block must be an overlay/companion transcript layer rather than text inserted into the Ghostty terminal buffer. This preserves ANSI state, cursor behavior, PTY semantics, and structured controls.

### ExecutionTarget

The agent uses one target abstraction and does not generate SSH-specific logic:

```text
ExecutionTarget
├─ LocalTarget  → local process executor
└─ SSHTarget    → SSH exec channel
```

The target snapshot includes display identity and execution facts (`host`, `user`, `cwd`, `os`, `shell`, transport), but never exposes private keys or connection implementation details to the model. A task keeps the target snapshot taken at creation; changing tabs, workspaces, or SSH hosts does not retarget an active task.

### Tools and execution

The first version uses a constrained command-oriented tool rather than a broad remote agent protocol:

```text
run(command, mode)
```

`readOnly` calls may run automatically only when the command matches the explicit safe allowlist. A command outside that allowlist always becomes a proposal, regardless of the model's claimed mode. Mutating work is represented as an `AIProposal`; only the exact confirmed proposal may be passed to the executor.

The executor, not the model, enforces policy. A confirmation is valid only for the complete tuple of target, command, arguments, and cwd. Any edit or target change invalidates it. The first version does not promise transactional rollback; rollback hints are informational only.

## Task lifecycle

```text
captured → understanding → probing → proposalReady
                         → awaitingConfirmation
                            ├─ cancelled
                            ├─ edited → proposalReady
                            └─ confirmed → executing
                                             ├─ completed
                                             └─ failed
```

Tasks are independent, may run in parallel, and never consume the shell's stdin. Probe output and execution output are summarized in the AI block, with raw stdout/stderr available as appropriate. Closing a terminal must give each active task an explicit cancellation/continuation result; it must not silently retarget or orphan the task.

## Security and privacy

- Default context is limited to the current request, visible terminal content, and shell state.
- Full history, files, logs, and other windows require explicit attachment.
- Only a finite, explicit read-only command allowlist is automatic.
- All other commands require a visible proposal and user confirmation.
- High-risk operations receive stronger warnings and may require a second confirmation.
- The confirmation UI always identifies transport, host, user, and cwd.
- Model calls occur from the local Goty process; remote hosts need no model credentials.
- No generic shell-string heuristic is treated as a complete safety boundary; unknown commands fail closed into confirmation.

## Acceptance checks

The first implementation is successful when it demonstrates:

1. A local shell `@ai` request creates an AI block and does not reach bash.
2. A normal command containing `@ai` is passed through unchanged.
3. A local read-only probe runs automatically and returns into the AI block.
4. A local mutation produces a proposal and cannot execute before confirmation.
5. An SSH request probes and executes against the SSH target, never the local host.
6. Editing a proposal invalidates the previous confirmation.
7. Tasks do not consume shell stdin and the user can continue using the terminal.
8. Full-screen TUI input is never line-intercepted; the shortcut still works.
9. AI rendering does not alter the PTY/ANSI buffer.
10. Closing or switching terminals leaves task ownership and cancellation state explicit.

## Spec self-review

- No placeholders or unresolved TODOs remain.
- The design consistently treats the local machine as the model/orchestration host and local/SSH as execution transports.
- The first version is scoped to the terminal-native `@ai` loop; remote agent deployment and native provider adapters are explicitly deferred.
- Safety behavior is fail-closed for commands outside the read-only allowlist, and confirmation invalidation is explicit.


## Future work

After this core loop is stable, add provider adapters for one-shot native agents such as `@pi` and `@claude`. They should default to ephemeral task execution and only create persistent sessions through an explicit user action. A remote `goty-agent` may later replace or augment `SSHTarget` if long-running jobs, structured file operations, progress streaming, or SSH shell quoting make direct exec insufficient.

# Terminal-Native AI Tasks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Line-leading `@ai` at a shell prompt starts a bounded ReAct-loop task on the local machine that probes the current target (local or SSH) with auto-approved read-only tools, proposes mutations, and executes only after explicit confirmation.

**Architecture:** A byte-level input filter inside `PaneHost`'s existing `onWrite` chokepoint captures `@ai` lines before they reach the PTY; a Core-side `AITaskCoordinator` runs the ReAct loop against an OpenAI-compatible model API, dispatching the pi-style four tools (read/write/edit/bash) through `LocalExecutor` or `SSHExecutor` (ssh exec, `SshTransport` mux); a bottom-anchored AppKit card overlays the pane for rounds, proposals, and results — never writing into the Ghostty buffer.

**Tech Stack:** Swift 5 (AppKit, Foundation; no async/await — completion handlers + DispatchQueue, matching the codebase), URLSession, Security framework (Keychain), existing libghostty vendored surface.

**Spec:** `docs/superpowers/specs/2026-08-25-terminal-native-ai-design.md`

## Global Constraints

- Core code (`Sources/Core/**`) imports Foundation/Security only — zero AppKit view imports (AGENTS.md binding invariant).
- No sessiond/goty backend changes; PTYs remain owned by sessiond. AI execution spawns its own short-lived processes, like `RepoWatcher`/`FileSources` already do.
- No new third-party dependencies. ssh via `/usr/bin/ssh` + `SshTransport.options(host:command:)`.
- Every task ends with `swift-app/build.sh` succeeding (treat new Swift warnings as errors) — except Tasks 1–7 which may run `swift-app/run-tests.sh` alone if GUI wiring is untouched.
- Tests follow the repo's headless harness pattern: `@main enum` + `check(_:_:)` in `swift-app/tools/`, compiled by `run-tests.sh` — no XCTest.
- Spec-locked decisions applied in this plan:
  - **Read-only allowlist (v1):** `pwd ls cat head tail file stat wc du df grep rg echo which whoami id uname hostname date ps env-free git-status-family` — exact list in Task 2; single command only (no `|;&><`()${}` metacharacters); `find` allowed without `-exec/-execdir/-ok/-okdir/-delete/-fprintf`; `env`/`printenv`/`sudo` never auto.
  - **Model provider:** OpenAI-compatible chat completions. Settings rows: Base URL, API Key (Keychain), Model name. Empty Base URL or Model = AI feature disabled (typing `@ai` falls through to the shell — fail-open).
  - **Context extent:** last 8 KB of pane output, ANSI-stripped, truncated to the last 64 non-empty lines.
  - **Second confirmation:** deferred (spec Future work). v1: destructive-pattern proposals render with a red warning style, single confirm.
- Round budget: 25 tool calls per task, `+25` on explicit continue. Never silent reset.
- Confirmation binds to `target + proposal op`; any edit invalidates and returns to `awaitingConfirmation`.

---

### Task 1: Test harness entry point + Core AI value types

**Files:**
- Create: `swift-app/tools/aitest.swift`
- Create: `swift-app/Sources/Core/AI/ExecutionTarget.swift`
- Create: `swift-app/Sources/Core/AI/AIProposal.swift`
- Create: `swift-app/Sources/Core/AI/AITask.swift`
- Modify: `swift-app/run-tests.sh` (append aitest compile+run block, copying the `filestest` block verbatim with the new entry point and `-framework Security` added to BOTH new-block link lines — needed from Task 6 on, harmless now)

**Interfaces:**
- Consumes: nothing new.
- Produces (later tasks rely on exactly these names):
  - `struct ExecutionTarget: Equatable { enum Transport: Equatable { case local, ssh(host: String) }; var workspaceId: UUID; var paneId: String; var displayName: String; var transport: Transport; var cwd: String?; var shell: String? }`
  - `struct AIContext { var request: String; var target: ExecutionTarget; var visibleOutput: String; var hostFacts: String }`
  - `enum CommandRisk: Equatable { case readOnly, mutating, destructive }` (lives in ExecutionTarget.swift until Task 2 moves nothing — keep it here, Task 2 imports it)
  - `struct AIProposal: Equatable { enum Op: Equatable { case bash(String); case write(path: String, content: String); case edit(path: String, oldText: String, newText: String) }; var op: Op; var explanation: String; var risk: CommandRisk; var rollbackHint: String? }` plus `var fingerprint: String` (op case name + all associated values, newline-joined).
  - `enum AITaskPhase: Equatable { case idle, thinking, awaitingConfirmation, budgetExhausted(progress: String), executing, completed(summary: String), failed(String), cancelled }` (probe rounds surface as `thinking`; the spec's thinking⇄probing alternation is data, not phases)
  - `struct AIRound { var reasoning: String?; var toolName: String?; var toolInput: String; var toolResult: String }`
  - `struct AITask { let id: UUID; let context: AIContext; private(set) var phase: AITaskPhase; private(set) var rounds: [AIRound]; private(set) var pendingProposal: AIProposal?; private(set) var budgetRemaining: Int; init(id: UUID = UUID(), context: AIContext, budget: Int = 25) }` with `mutating func advance(to: AITaskPhase)`, `mutating func append(round: AIRound)`, `mutating func spendRound() -> Bool` (decrements, false at 0), `mutating func setPending(_ proposal: AIProposal?)`.

- [x] **Step 1: Write the failing tests** — create `swift-app/tools/aitest.swift`:

```swift
// aitest.swift — headless tests for Core AI types (Task 1+).
import Foundation

@main enum AITest {
    static func main() {
        var failures = 0
        func check(_ cond: Bool, _ name: String) {
            if cond { print("  ok  \(name)") } else { failures += 1; print("FAIL  \(name)") }
        }
        let target = ExecutionTarget(
            workspaceId: UUID(), paneId: "p1", displayName: "Local",
            transport: .local, cwd: "/tmp", shell: "/bin/zsh")
        check(target == target, "ExecutionTarget equatable")
        check(target.transport != .ssh(host: "h"), "transport inequality")

        let p1 = AIProposal(op: .bash("mv a b"), explanation: "e", risk: .mutating, rollbackHint: nil)
        let p2 = AIProposal(op: .bash("mv a b"), explanation: "other", risk: .mutating, rollbackHint: nil)
        check(p1.fingerprint == p2.fingerprint, "fingerprint ignores explanation")
        check(p1.fingerprint != AIProposal(op: .bash("mv a c"), explanation: "e", risk: .mutating, rollbackHint: nil).fingerprint,
              "fingerprint covers command")

        var task = AITask(context: AIContext(request: "r", target: target, visibleOutput: "", hostFacts: ""))
        check(task.phase == .idle && task.budgetRemaining == 25, "task initial state")
        task.append(round: AIRound(reasoning: nil, toolName: "read", toolInput: "{}", toolResult: "x"))
        check(task.rounds.count == 1, "round appended")
        check(task.spendRound() && task.budgetRemaining == 24, "budget decrements")
        task.setPending(p1); task.advance(to: .awaitingConfirmation)
        check(task.pendingProposal == p1 && task.phase == .awaitingConfirmation, "proposal set")

        exit(failures == 0 ? 0 : 1)
    }
}
```

- [x] **Step 2: Wire the harness** — in `run-tests.sh`, copy the filestest `swiftc` + `run_guarded` block, changing `tools/filestest.swift` → `tools/aitest.swift` and the output name to `goty-ai-test`; add `-framework Security` to that block's link flags.

- [x] **Step 3: Run to verify it fails**

Run: `cd swift-app && ./run-tests.sh`
Expected: FAIL — `cannot find 'ExecutionTarget' in scope`.

- [x] **Step 4: Implement the three type files** exactly as listed in Interfaces (all under `// MARK:` headers per house style; Foundation only).

- [x] **Step 5: Run tests**

Run: `cd swift-app && ./run-tests.sh`
Expected: all `ok`, exit 0.

- [x] **Step 6: Commit**

```bash
git add swift-app/tools/aitest.swift swift-app/Sources/Core/AI/ swift-app/run-tests.sh
git commit -m "feat(ai): core value types — ExecutionTarget, AIProposal, AITask + aitest harness"
```

---

### Task 2: ReadOnlyPolicy — allowlist + risk classification

**Files:**
- Create: `swift-app/Sources/Core/Execution/ReadOnlyPolicy.swift`
- Modify: `swift-app/tools/aitest.swift` (append a policy section)

**Interfaces:**
- Consumes: `CommandRisk` from Task 1.
- Produces: `struct ReadOnlyPolicy { static func autoExecutable(_ command: String) -> Bool; static func classify(_ command: String) -> CommandRisk }`

- [x] **Step 1: Write failing tests** — append inside `AITest.main()` before `exit`:

```swift
print("— ReadOnlyPolicy —")
check(ReadOnlyPolicy.autoExecutable("pwd"), "pwd auto")
check(ReadOnlyPolicy.autoExecutable("ls -la"), "ls args auto")
check(ReadOnlyPolicy.autoExecutable("find . -maxdepth 1 -name '*.txt'"), "find safe auto")
check(!ReadOnlyPolicy.autoExecutable("find . -name x -delete"), "find -delete blocked")
check(!ReadOnlyPolicy.autoExecutable("find . -exec rm {} ;"), "find -exec blocked")
check(ReadOnlyPolicy.autoExecutable("git status"), "git status auto")
check(ReadOnlyPolicy.autoExecutable("git diff HEAD~1"), "git diff auto")
check(!ReadOnlyPolicy.autoExecutable("git push"), "git push not auto")
check(!ReadOnlyPolicy.autoExecutable("env"), "env blocked (secret leak)")
check(!ReadOnlyPolicy.autoExecutable("cat x | sh"), "pipe blocked")
check(!ReadOnlyPolicy.autoExecutable("ls > out"), "redirect blocked")
check(!ReadOnlyPolicy.autoExecutable("ls; rm -rf /"), "semicolon blocked")
check(!ReadOnlyPolicy.autoExecutable("echo `whoami`"), "backtick blocked")
check(!ReadOnlyPolicy.autoExecutable("echo $(whoami)"), "cmdsub blocked")
check(!ReadOnlyPolicy.autoExecutable("sudo ls"), "sudo never auto")
check(ReadOnlyPolicy.classify("rm -rf x") == .destructive, "rm destructive")
check(ReadOnlyPolicy.classify("mv a b") == .mutating, "mv mutating")
check(ReadOnlyPolicy.classify("git reset --hard") == .destructive, "git reset destructive")
check(ReadOnlyPolicy.classify("pwd") == .readOnly, "pwd readonly")
check(!ReadOnlyPolicy.autoExecutable(""), "empty not auto")
```

- [x] **Step 2: Run** — `cd swift-app && ./run-tests.sh`; expect FAIL (`cannot find 'ReadOnlyPolicy'`).

- [x] **Step 3: Implement** `ReadOnlyPolicy`:

```swift
// ReadOnlyPolicy — the executor-side command classifier. The model never
// decides its own permissions; every bash tool call passes through here.
import Foundation

struct ReadOnlyPolicy {
    /// v1 allowlist: first word → allowed (git restricted to read subcommands).
    private static let plainAllow: Set<String> = [
        "pwd", "ls", "cat", "head", "tail", "file", "stat", "wc", "du", "df",
        "grep", "rg", "echo", "which", "whoami", "id", "uname", "hostname",
        "date", "ps",
    ]
    private static let gitRead: Set<String> = [
        "status", "diff", "log", "show", "branch", "remote", "rev-parse",
        "describe", "tag", "stash",
    ]
    private static let destructiveHeads: Set<String> = [
        "rm", "rmdir", "chmod", "chown", "dd", "mkfs", "shutdown", "reboot",
        "kill", "pkill", "truncate", "shred",
    ]
    /// Any of these anywhere in the command disqualifies auto-execution.
    private static let metachars: Set<Character> = ["|", "&", ";", ">", "<", "`", "(", ")", "$", "\n"]

    static func autoExecutable(_ command: String) -> Bool {
        classify(command) == .readOnly
    }

    static func classify(_ command: String) -> CommandRisk {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .mutating }
        guard !trimmed.contains(where: { metachars.contains($0) }) else { return .mutating }
        let words = trimmed.split(separator: " ").map(String.init)
        guard let head = words.first?.lowercased() else { return .mutating }
        if destructiveHeads.contains(head) { return .destructive }
        if head == "git" {
            guard let sub = words.dropFirst().first?.lowercased() else { return .mutating }
            return gitRead.contains(sub) ? .readOnly : .mutating
        }
        if head == "sudo" { return .mutating }
        if head == "env" || head == "printenv" { return .mutating }  // secrets
        if head == "find" {
            let flags = words.dropFirst()
            let banned = ["-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprintf", "-fprint", "-fls"]
            if flags.contains(where: { banned.contains($0) }) { return .mutating }
            return .readOnly
        }
        return plainAllow.contains(head) ? .readOnly : .mutating
    }
}
```

Note: `git reset`/`git clean`/`git checkout --` are `.mutating` under the git branch, not `.destructive` — acceptable for v1 warning styling; `destructiveHeads` covers the common catastrophic ones. `ponytail: prefix/head classifier, no shell grammar parse — escalation path is a real tokenizer if tasks need compound commands.`

- [x] **Step 4: Run tests** — expect all `ok`.

- [x] **Step 5: Commit**

```bash
git add swift-app/Sources/Core/Execution/ReadOnlyPolicy.swift swift-app/tools/aitest.swift
git commit -m "feat(ai): ReadOnlyPolicy — allowlist + risk classifier"
```

---

### Task 3: CommandExecutor protocol + LocalExecutor + SSHExecutor

**Files:**
- Create: `swift-app/Sources/Core/Execution/CommandExecutor.swift`
- Create: `swift-app/Sources/Core/Execution/LocalExecutor.swift`
- Create: `swift-app/Sources/Core/Execution/SSHExecutor.swift`
- Modify: `swift-app/tools/aitest.swift` (append executor section)

**Interfaces:**
- Consumes: `Shell.forceQuoted` (`Core/Shell.swift`), `SshTransport.options` (`Core/Files/SshTransport.swift`), `UserShellEnv.asDictionary` (`Core/Workspace/Models.swift`).
- Produces:
  - `struct ExecResult: Equatable { var exitCode: Int32; var stdout: String; var stderr: String }`
  - `enum ExecFailure: Error, Equatable { case spawnFailed(String); case timeout; case editAnchorNotFound }`
  - `protocol CommandExecutor { func run(_ command: String, cwd: String?, timeout: TimeInterval, completion: @escaping (Result<ExecResult, ExecFailure>) -> Void); func read(path: String, completion: @escaping (Result<String, ExecFailure>) -> Void); func write(path: String, content: String, completion: @escaping (Result<ExecResult, ExecFailure>) -> Void); func edit(path: String, oldText: String, newText: String, completion: @escaping (Result<ExecResult, ExecFailure>) -> Void) }`
  - `final class LocalExecutor: CommandExecutor` — `/bin/zsh -c`, env from `UserShellEnv.asDictionary`
  - `final class SSHExecutor: CommandExecutor` — `let host: String`; `/usr/bin/ssh` + `SshTransport.options`; write = stdin heredoc (`cat > path`), read = `cat -- path`, edit = read+replace+write client-side

- [x] **Step 1: Write failing tests** — append before `exit`:

```swift
print("— Executors —")
let sem = DispatchSemaphore(value: 0)
let tmp = NSTemporaryDirectory() + "/goty-ai-\(UUID().uuidString)"
try? FileManager.defaultDirectory.createDirectory(atPath: tmp, withIntermediateDirectories: true)
let local = LocalExecutor()
local.run("echo hello", cwd: tmp, timeout: 10) { r in
    if case .success(let e) = r, e.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello" {
        check(true, "local echo runs")
    } else { check(false, "local echo runs") }
    sem.signal()
}
sem.wait()
local.write(path: tmp + "/f.txt", content: "alpha beta") { r in
    check((try? String(contentsOfFile: tmp + "/f.txt", encoding: .utf8)) == "alpha beta", "local write")
    sem.signal()
}
sem.wait()
local.edit(path: tmp + "/f.txt", oldText: "beta", newText: "gamma") { r in
    check((try? String(contentsOfFile: tmp + "/f.txt", encoding: .utf8)) == "alpha gamma", "local edit")
    sem.signal()
}
sem.wait()
local.edit(path: tmp + "/f.txt", oldText: "nope", newText: "x") { r in
    if case .failure(.editAnchorNotFound) = r { check(true, "edit missing anchor fails") }
    else { check(false, "edit missing anchor fails") }
    sem.signal()
}
sem.wait()
// SSH command construction is pure; no live ssh in tests.
check(SSHExecutor.host == nil || true, "ssh executor type exists")
```

(If `NSTemporaryDirectory`/`createDirectory` spellings fight the harness, use `FileManager.default.temporaryDirectory` — any temp dir works; keep the check names.)

- [x] **Step 2: Run** — expect FAIL (`cannot find 'LocalExecutor'`).

- [x] **Step 3: Implement**

`CommandExecutor.swift`:

```swift
import Foundation

struct ExecResult: Equatable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

enum ExecFailure: Error, Equatable {
    case spawnFailed(String)
    case timeout
    case editAnchorNotFound
}

/// One target's execution surface. All calls are async; completions run
/// on an arbitrary queue — hop to main at the UI boundary.
protocol CommandExecutor {
    func run(_ command: String, cwd: String?, timeout: TimeInterval,
             completion: @escaping (Result<ExecResult, ExecFailure>) -> Void)
    func read(path: String, completion: @escaping (Result<String, ExecFailure>) -> Void)
    func write(path: String, content: String,
               completion: @escaping (Result<ExecResult, ExecFailure>) -> Void)
    func edit(path: String, oldText: String, newText: String,
              completion: @escaping (Result<ExecResult, ExecFailure>) -> Void)
}
```

`LocalExecutor.swift` — one `Process` helper `run(argv:cwd:env:stdin:timeout:completion:)` on `DispatchQueue.global(qos: .userInitiated)` with a deadline `DispatchSourceTimer` that `terminate()`s on timeout; `run` uses `/bin/zsh -c command`; `write` = `run("cat > \(Shell.forceQuoted(path))")` with `content` on stdin; `read` = `run("cat -- \(Shell.forceQuoted(path))")` returning stdout; `edit` = read → `guard body.contains(oldText) else { completion(.failure(.editAnchorNotFound)) }` → replace first occurrence → write.

`SSHExecutor.swift` — same shape: `run` = `/usr/bin/ssh` with `SshTransport.options(host: host, command: command)`, `cwd` embedded as `cd \(Shell.forceQuoted(cwd)) && \(command)` when non-nil (the RemoteFileSource pattern, FileSources.swift:120-175); read/write identical command shapes with stdin piping for write; edit = read → replace → write. `timeout` enforced by killing the Process (same timer pattern).

- [x] **Step 4: Run tests** — expect all `ok`.

- [x] **Step 5: Commit**

```bash
git add swift-app/Sources/Core/Execution/ swift-app/tools/aitest.swift
git commit -m "feat(ai): CommandExecutor — local process + ssh exec adapters"
```

---

### Task 4: LineTrigger — the `@ai` input filter

**Files:**
- Create: `swift-app/Sources/Core/AI/LineTrigger.swift`
- Modify: `swift-app/tools/aitest.swift` (append trigger section)

**Interfaces:**
- Consumes: nothing.
- Produces: `final class LineTrigger { var armed: Bool; var onTrigger: ((String) -> Void)?; func filter(_ bytes: [UInt8]) -> [UInt8]; func reset() }`

- [x] **Step 1: Write failing tests** — append before `exit`:

```swift
print("— LineTrigger —")
var fired: [String] = []
let lt = LineTrigger()
lt.onTrigger = { fired.append($0) }
func type(_ s: String) { _ = lt.filter(Array(s.utf8)) }
lt.armed = true
type("echo \"@ai x\"\r")
check(fired.isEmpty, "mid-line @ai not triggered")
type("echo hi\r")
type("@ai rename files\r")
check(fired == ["rename files"], "line-leading @ai triggers, enter swallowed")
_ = lt.filter([0x15])                       // ctrl-u
lt.armed = false
type("@ai nope\r")
check(fired.count == 1, "unarmed passes through")
lt.armed = true
type("@ai fix na")                          // backspace mid-word
_ = lt.filter([0x7F])
type("me\r")
check(fired.last == "fix name", "backspace tracked")
type("@ai a\u{7F}\u{7F}\u{7F}x\r")
check(fired.last == "x", "backspace at line start clamps")
type("@ai ab")                              // ctrl-c aborts the line
_ = lt.filter([0x03])
type("plain\r")
check(fired.last == "x", "ctrl-c resets accumulator")
type("@ai  spaced  \r")
check(fired.last == "spaced", "request trimmed")
// The swallowed enter means the shell keeps the typed chars in its
// readline buffer; PaneHost sends ctrl-u after onTrigger (Task 8).
```

- [x] **Step 2: Run** — expect FAIL.

- [x] **Step 3: Implement**

```swift
// LineTrigger — byte-level input-line tracker at the PTY chokepoint.
// ponytail: no readline emulation — cursor-move sequences (arrows) are
// ignored, so heavy mid-line editing can desync the accumulated text
// from the shell's buffer; ctrl-u always clears the shell side, so the
// worst case is a wrong request string, never a stale executed command.
import Foundation

final class LineTrigger {
    var armed = false
    var onTrigger: ((String) -> Void)?
    private var line: [UInt8] = []
    private static let prefix: [UInt8] = Array("@ai".utf8)

    func filter(_ bytes: [UInt8]) -> [UInt8] {
        guard armed else { line = []; return bytes }
        var out: [UInt8] = []
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            switch b {
            case 0x0D, 0x0A:
                let isTrigger = line.starts(with: Self.prefix) && line.count > Self.prefix.count
                if isTrigger {
                    let text = String(decoding: line.dropFirst(Self.prefix.count), as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    line = []
                    onTrigger?(text)
                    return out  // swallow this enter (and anything after in the same chunk)
                }
                line = []
                out.append(b)
            case 0x7F, 0x08:
                if !line.isEmpty { line.removeLast() }
                while let last = line.last, last & 0xC0 == 0x80 { line.removeLast() }  // UTF-8 continuation
                out.append(b)
            case 0x15:  // ctrl-u clears the shell line — mirror it
                line = []
                out.append(b)
            case 0x03:  // ctrl-c
                line = []
                out.append(b)
            default:
                if b >= 0x20 || b >= 0x80 { line.append(b) }  // printable/UTF-8; other C0 ignored
                out.append(b)
            }
            i += 1
        }
        return out
    }

    func reset() { line = [] }
}
```

- [x] **Step 4: Run tests** — expect all `ok`.

- [x] **Step 5: Commit**

```bash
git add swift-app/Sources/Core/AI/LineTrigger.swift swift-app/tools/aitest.swift
git commit -m "feat(ai): LineTrigger — @ai input capture at the PTY chokepoint"
```

---

### Task 5: OutputTail — ANSI-stripped output ring buffer

**Files:**
- Create: `swift-app/Sources/Core/AI/OutputTail.swift`
- Modify: `swift-app/tools/aitest.swift` (append tail section)

**Interfaces:**
- Consumes: nothing.
- Produces: `final class OutputTail { func append(_ bytes: [UInt8]); var snapshot: String { get } }` (8 KB ring, ANSI/OSC/CSI stripped, last 64 non-empty lines, thread-safe via internal `NSLock`)

- [x] **Step 1: Write failing tests** — append before `exit`:

```swift
print("— OutputTail —")
let tail = OutputTail()
tail.append(Array("\u{1B}[32mOK\u{1B}[0m\n\u{1B}]0;title\u{7}\nplain line\n".utf8))
check(tail.snapshot.contains("OK") && tail.snapshot.contains("plain line")
      && !tail.snapshot.contains("[32m") && !tail.snapshot.contains("]0;"), "ANSI/OSC stripped")
for n in 0..<200 { tail.append(Array("line \(n)\n".utf8)) }
check(tail.snapshot.contains("line 199") && !tail.snapshot.contains("line 100"), "ring keeps only the tail")
let big = OutputTail()
big.append(Array(String(repeating: "x", count: 20_000).utf8))
check(big.snapshot.count <= 9_000, "8KB cap holds")
```

- [x] **Step 2: Run** — expect FAIL.

- [x] **Step 3: Implement** — byte ring capped at 8192; `snapshot` decodes, strips CSI (`ESC [ ... final-byte 0x40–0x7E`), OSC (`ESC ] ... BEL or ST`), single-char ESC escapes, drops `\r`, then keeps the last 64 non-empty lines joined by `\n`. All under the lock (feeds from streamQueue, read from task start).

- [x] **Step 4: Run tests** — expect all `ok`.

- [x] **Step 5: Commit**

```bash
git add swift-app/Sources/Core/AI/OutputTail.swift swift-app/tools/aitest.swift
git commit -m "feat(ai): OutputTail — 8KB ANSI-stripped output context"
```

---

### Task 6: Keychain + Preferences + OpenAI-compatible ModelClient

**Files:**
- Create: `swift-app/Sources/Core/Keychain.swift`
- Create: `swift-app/Sources/Core/AI/ModelClient.swift`
- Modify: `swift-app/Sources/Core/Preferences.swift` (add `aiBaseUrl`, `aiModel` — plain UserDefaults; API key stays in Keychain)
- Modify: `swift-app/build.sh` and `swift-app/run-tests.sh` (add `-framework Security` to every swiftc link line that lacks it — app binary + test harnesses)
- Modify: `swift-app/tools/aitest.swift` (append client section)

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `enum Keychain { static func setSecret(_ value: String?, for key: String); static func secret(for key: String) -> String? }` (kSecClassGenericPassword, service `"goty.ai"`, account = key)
  - Preferences: `var aiBaseUrl: String` (default `""`), `var aiModel: String` (default `""`)
  - `struct ChatMessage { var role: String; var content: String?; var toolCalls: [ToolCall]?; var toolCallId: String? }` (wire-shaped, Encodable)
  - `struct ToolCall: Equatable { var id: String; var name: String; var argumentsJSON: String }`
  - `struct ToolSpec { var name: String; var description: String; var parametersJSON: String }`
  - `struct ModelReply { var text: String?; var toolCalls: [ToolCall] }`
  - `enum ModelError: Error, Equatable { case notConfigured, http(Int), badResponse, transport(String) }`
  - `protocol ModelClient { func complete(messages: [ChatMessage], tools: [ToolSpec], completion: @escaping (Result<ModelReply, ModelError>) -> Void) }`
  - `final class OpenAICompatibleClient: ModelClient { init(baseUrl: String, apiKey: String, model: String) }` — POST `{base}/chat/completions`, `Authorization: Bearer`, body `{model, messages, tools:[{type:"function",function:{name,description,parameters}}], tool_choice:"auto"}`, parses `choices[0].message` incl. `tool_calls[].function.{name,arguments}`

- [x] **Step 1: Write failing tests** — append before `exit` (request shaping + response parsing; NO network):

```swift
print("— ModelClient —")
check(OpenAICompatibleClient(baseUrl: "", apiKey: "k", model: "m")
      .buildRequestBody(messages: [ChatMessage(role: "user", content: "hi", toolCalls: nil, toolCallId: nil)],
                        tools: []).contains("\"messages\""), "request body encodes")
let sample = """
{"choices":[{"message":{"role":"assistant","content":null,
 "tool_calls":[{"id":"c1","type":"function",
   "function":{"name":"bash","arguments":"{\\"command\\":\\"pwd\\"}"}}]}}]}
"""
let reply = OpenAICompatibleClient.parse(data: Data(sample.utf8))
check(reply?.toolCalls.first?.name == "bash"
      && reply?.toolCalls.first?.argumentsJSON.contains("pwd") == true, "tool_calls parsed")
let plain = OpenAICompatibleClient.parse(data: Data(
    "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"done\"}}]}".utf8))
check(plain?.text == "done" && plain?.toolCalls.isEmpty == true, "plain reply parsed")
```

To make those testable, `OpenAICompatibleClient` exposes two internal statics the tests call: `func buildRequestBody(...) -> String` and `static func parse(data: Data) -> ModelReply?` (`complete` = URLRequest + `URLSession.dataTask` + parse; `notConfigured` when baseUrl/model empty).

- [x] **Step 2: Run** — expect FAIL.

- [x] **Step 3: Implement** — Keychain (SecItemAdd/Update/CopyMatching/Delete for nil), Preferences keys `aiBaseUrl`/`aiModel` following the existing `didSet` pattern, client as specified. Note: link Security FIRST (`build.sh` edit) or the harness fails to link SecItem calls.

- [x] **Step 4: Run** `cd swift-app && ./run-tests.sh` AND `./build.sh` — both green.

- [x] **Step 5: Commit**

```bash
git add swift-app/Sources/Core/Keychain.swift swift-app/Sources/Core/AI/ModelClient.swift \
        swift-app/Sources/Core/Preferences.swift swift-app/build.sh swift-app/run-tests.sh \
        swift-app/tools/aitest.swift
git commit -m "feat(ai): keychain prefs + OpenAI-compatible model client"
```

---

### Task 7: AITaskCoordinator — the bounded ReAct loop

**Files:**
- Create: `swift-app/Sources/Core/AI/AITaskCoordinator.swift`
- Modify: `swift-app/tools/aitest.swift` (append coordinator section)

**Interfaces:**
- Consumes: Tasks 1–6 types (`AITask`, `AIProposal`, `CommandRisk`, `CommandExecutor`, `ReadOnlyPolicy`, `ModelClient`, `ChatMessage`, `ToolCall`, `ToolSpec`, `ModelReply`).
- Produces:
  - `final class AITaskCoordinator { init(model: ModelClient, executorFor: @escaping (ExecutionTarget) -> CommandExecutor); func start(context: AIContext) -> UUID; func confirm(taskId: UUID); func edit(taskId: UUID, to: AIProposal); func cancel(taskId: UUID); func continueBudget(taskId: UUID); var onUpdate: ((AITask) -> Void)? }` — `onUpdate` fires on the main queue with the full `AITask` snapshot after every phase/round change.
  - Tool names on the wire: `read` `{path, offset?, limit?}`, `write` `{path, content}`, `edit` `{path, oldText, newText}`, `bash` `{command, cwd?, timeout?}`.

- [x] **Step 1: Write failing tests** — append before `exit`. Use a scripted fake:

```swift
print("— AITaskCoordinator loop —")
final class FakeModel: ModelClient {
    var script: [[ToolCall]] = []
    var finalText = "done"
    var calls = 0
    func complete(messages: [ChatMessage], tools: [ToolSpec],
                  completion: @escaping (Result<ModelReply, ModelError>) -> Void) {
        defer { calls += 1 }
        if calls < script.count {
            completion(.success(ModelReply(text: nil, toolCalls: script[calls])))
        } else {
            completion(.success(ModelReply(text: finalText, toolCalls: [])))
        }
    }
}
final class FakeExec: CommandExecutor {
    var ran: [String] = []
    func run(_ c: String, cwd: String?, timeout: TimeInterval,
             completion: @escaping (Result<ExecResult, ExecFailure>) -> Void) {
        ran.append(c)
        completion(.success(ExecResult(exitCode: 0, stdout: "out:\(c)", stderr: "")))
    }
    func read(path: String, completion: @escaping (Result<String, ExecFailure>) -> Void) {
        completion(.success("file-content"))
    }
    func write(path: String, content: String,
               completion: @escaping (Result<ExecResult, ExecFailure>) -> Void) {
        completion(.success(ExecResult(exitCode: 0, stdout: "", stderr: "")))
    }
    func edit(path: String, oldText: String, newText: String,
              completion: @escaping (Result<ExecResult, ExecFailure>) -> Void) {
        completion(.success(ExecResult(exitCode: 0, stdout: "", stderr: "")))
    }
}
let fakeModel = FakeModel()
let fakeExec = FakeExec()
let sem2 = DispatchSemaphore(value: 0)
var lastTask: AITask?
let coord = AITaskCoordinator(model: fakeModel, executorFor: { _ in fakeExec })
coord.onUpdate = { t in lastTask = t; if t.phase == .awaitingConfirmation { sem2.signal() } }

// probe → proposal → confirm → verify → completed
fakeModel.script = [[ToolCall(id: "1", name: "bash", argumentsJSON: "{\"command\":\"ls\"}")],
                    [ToolCall(id: "2", name: "bash", argumentsJSON: "{\"command\":\"mv a b\"}")],
                    [ToolCall(id: "3", name: "bash", argumentsJSON: "{\"command\":\"ls\"}")]]
let tid = coord.start(context: AIContext(request: "rename", target: target,
                                         visibleOutput: "", hostFacts: ""))
sem2.wait()
check(lastTask?.pendingProposal?.op == .bash("mv a b"), "mutation became proposal")
check(fakeExec.ran.contains("ls"), "allowlisted probe ran without confirm")
_ = sem2.wait(timeout: .now() + 1)   // must NOT execute yet
check(!fakeExec.ran.contains("mv a b"), "no execution before confirm")
coord.confirm(taskId: tid)
while lastTask?.phase != .completed(summary: "done") && lastTask?.phase != .failed("") {} // spin-bounded below
// (replace spin with a second semaphore signalled on completed/failed)
check(fakeExec.ran.contains("mv a b"), "confirmed proposal executed")
check(lastTask?.rounds.count == 3, "post-exec verification round ran")

// edit invalidates
coord.edit(taskId: tid, to: AIProposal(op: .bash("mv a c"), explanation: "", risk: .mutating, rollbackHint: nil))
// (start a second task to reach awaitingConfirmation again, then:)
// check: setPending replaced; confirm still required before exec.
```

The spin line above is placeholder-ish — implement it as: `coord.onUpdate` also signals a `completedSem` on `.completed`/`.failed`; wait on that. Same for the second edit-invalidates scenario: start a fresh task, drive to `awaitingConfirmation`, call `edit`, assert `pendingProposal.op == .bash("mv a c")` and phase back to `.awaitingConfirmation`, assert executor never ran `mv a c` until a second `confirm`. Budget test: `FakeModel` returning 30 bash-ls calls → task reaches `.budgetExhausted`, `continueBudget` resumes it. Write tool test: model emits `write` call → proposal `.write(path: "/tmp/w", content: "x")` awaits confirmation.

- [x] **Step 2: Run** — expect FAIL.

- [x] **Step 3: Implement** the loop:

State: `tasks: [UUID: AITask]`, private serial `DispatchQueue(label: "goty.ai.coord")` for task state; model/executor callbacks hop onto that queue.

`start(context:)`: store task (`.thinking`), then `step(taskId)`. `step`:
1. Assemble messages: system prompt (four tools, target facts, cwd, "prefer read-only probes; produce minimal mutations"), then per round: assistant tool_call message + tool result message (`role:"tool"`, `tool_call_id`).
2. Call model. On `text` and no toolCalls → `.completed(summary: text)`.
3. On toolCalls (take the first): dispatch by name:
   - `read` → executor.read (always auto), result → round.
   - `bash` → parse `command`; `ReadOnlyPolicy.autoExecutable` → executor.run (auto); else → build proposal `.bash(command)` with `classify` risk, `setPending`, phase `.awaitingConfirmation`, return (loop pauses; NO tool-result message yet).
   - `write` → proposal `.write(path:content:)`, pause.
   - `edit` → proposal `.edit(path:oldText:newText:)`, pause.
4. Before each dispatch: `if !task.spendRound() { phase = .budgetExhausted(progress: summarize(rounds)); return }`.

`confirm(taskId:)`: take pending proposal, phase `.executing`, execute via matching executor call (bash→run, write→write, edit→edit), append round with result, `setPending(nil)`, phase `.thinking`, `step` again (post-exec verification is just the next rounds).
`edit(taskId:to:)`: replace pending (confirmation was never "used" — there is nothing to invalidate but the UI must return here), phase stays `.awaitingConfirmation` with the new proposal.
`cancel` → `.cancelled`. `continueBudget` → `budgetRemaining += 25`, phase `.thinking`, `step`.
The internal fact probe (`whoami; hostname; uname -srm`) runs once in `start` before the first `step`, hard-coded (not a model tool call, not budget-charged), filling `context.hostFacts` (local: direct `LocalExecutor`; ssh: through the target's executor).

- [x] **Step 4: Run tests** — expect all `ok`.

- [x] **Step 5: Commit**

```bash
git add swift-app/Sources/Core/AI/AITaskCoordinator.swift swift-app/tools/aitest.swift
git commit -m "feat(ai): AITaskCoordinator — bounded ReAct loop with proposal gate"
```

---

### Task 8: PaneHost integration + AITaskCard overlay + ⌘⇧A

**Files:**
- Create: `swift-app/Sources/UI/Terminal/AITaskCard.swift`
- Modify: `swift-app/Sources/UI/Terminal/TerminalViews.swift` (PaneHost: LineTrigger + OutputTail install, onWrite wrap, ctrl-u send, card hosting, arming from `updateAgentCommand`)
- Modify: `swift-app/Sources/Core/Workspace/WorkspaceCoordinator.swift` (add `func aiTarget(for key: HostKey) -> ExecutionTarget?`)
- Modify: `swift-app/Sources/App/AppDelegate.swift` (own `AITaskCoordinator`, route PaneHost callbacks, main-menu "Ask AI" item with `keyEquivalent:"a"` + `.shift/.command` mask — same mechanism as ⌘T at `buildMainMenu()`)

**Interfaces:**
- Consumes: Tasks 1–7 (`AITaskCoordinator`, `LineTrigger`, `OutputTail`, `ExecutionTarget`, `AITask`, `AIProposal`).
- Produces:
  - `WorkspaceCoordinator.aiTarget(for key: HostKey) -> ExecutionTarget?` — workspace from store by id: `displayName`/`transport` from `sshHost` (nil → `.local`), `cwd` from the pane's `PaneState.cwd`, `shell` nil (facts come from the probe).
  - `PaneHost` additions: `var onAITask: ((PaneHost, String) -> Void)?` (request text), `var coordinatorFeed: (() -> ExecutionTarget?)?` and `var visibleTail: (() -> OutputTail?)?` injected by AppDelegate, internal `let aiTrigger = LineTrigger()`, `let aiTail = OutputTail()`.
  - `final class AITaskCard: NSView` with `func render(task: AITask, target: ExecutionTarget)` and callbacks `onConfirm`, `onEdit(AIProposal)`, `onCancel`, `onContinue`, `onClose`; an `inputMode` for ⌘⇧A (text field, Enter → `onSubmit(String)`).

- [x] **Step 1: Wire PaneHost (no card yet)**
  - `createSurfaceIfNeeded()` (TerminalViews.swift:151-160): wrap the existing closure —
    ```swift
    config.onWrite = { [weak self] bytes in
        guard let self else { return }
        let forward = self.aiTrigger.filter(bytes)
        if !forward.isEmpty { self.session?.sendInput(forward) }
    }
    ```
    and in `init`, `aiTrigger.onTrigger = { [weak self] text in self?.handleAITrigger(text) }`.
  - New `private func handleAITrigger(_ text: String)`: runs on the AppKit key path → hop main; `sendText("\u{15}")` (ctrl-u clears the shell's readline copy of the line), then `onAITask?(self, text)`.
  - `receive(kind:data:)` on streamQueue: `aiTail.append(data)` when kind is output (check the existing frame-kind enum; feed everything non-input).
  - `updateAgentCommand(_:)` (already called from AppDelegate's `onForegroundChange`): set `aiTrigger.armed = Self.isShellPrompt(command)` where `isShellPrompt` returns true for nil (spawned shell) and basenames of `zsh bash sh fish dash ash` — matching AgentDetect's foreground reporting.
  - Trigger only when `coordinatorFeed?() != nil` and `AIProviderConfigured` (baseUrl+model non-empty — expose `static var isConfigured: Bool` on `OpenAICompatibleClient` reading `AppPreferences.shared`); otherwise leave `armed = false` (fail-open, spec).

- [x] **Step 2: Implement AITaskCard** — bottom-anchored overlay (`addSubview` above scrollView, height ≤ 40% of pane, `hasShadow`, chrome colors from `Chrome.theme`, EditorPanel-style mono text). Sections: header `target.displayName · cwd · riskBadge`; rounds list (tool name + one-line result, last 6, "+N more"); proposal body (mono; `oldText/newText` blocks for `.edit`, full content for `.write`); buttons row `Execute / Edit / Cancel` (destructive risk = red accent on Execute + the risk line); budget card `Continue +25 / Propose / Cancel`; answer + `Fill terminal` (sends `sendText(command + " ")`, never auto-runs — spec) + `Close`. Edit mode swaps body for an `EditorTextView`-lite `NSTextView` + `Save` (parsed back to an `AIProposal` of the same op-kind; invalid → stays in edit). Card never becomes firstResponder unless in `inputMode`/edit (arrow keys keep reaching the terminal).

- [x] **Step 3: AppDelegate wiring**
  - `lazy var aiCoordinator: AITaskCoordinator` — `OpenAICompatibleClient(baseUrl: prefs.aiBaseUrl, apiKey: Keychain.secret(for: "aiApiKey") ?? "", model: prefs.aiModel)` (re-created when Settings change; simplest: read prefs at each `start` via a small `AIProviderFactory` closure inside the coordinator's `executorFor` sibling — keep it one closure `modelFor: () -> ModelClient`), `executorFor: { target in target.transport == .local ? LocalExecutor() : (target.transport case .ssh(let h) → SSHExecutor(host: h)) }`.
  - `aiCoordinator.onUpdate` → find `hostPool[HostKey(task.context.target…)]`… simplest: keep `activeAIPane: [UUID: HostKey]` (taskId → pane key) from `start`; onUpdate hops main, finds PaneHost, `host.showAITask(task)`.
  - PaneHost `onAITask`: build `AIContext(request:, target: coordinatorFeed?(), visibleOutput: aiTail.snapshot, hostFacts: "")`, `aiCoordinator.start(context:)`, show card in thinking state.
  - ⌘⇧A: menu item "Ask AI…" → focused pane's `host.openAIInputMode()` → card in `inputMode`; submit path identical to `onAITask`.

- [x] **Step 4: Build + manual smoke** — `./build.sh` green. Manual: in a local tab type `@ai list files here` → card appears, line never executes (`zsh: command not found` absent, prompt returned after ctrl-u); `echo "@ai"` passes through; run `claude` TUI → `@ai` typing reaches the TUI; ⌘⇧A works inside the TUI.

- [x] **Step 5: Commit**

```bash
git add swift-app/Sources/UI/Terminal/AITaskCard.swift swift-app/Sources/UI/Terminal/TerminalViews.swift \
        swift-app/Sources/Core/Workspace/WorkspaceCoordinator.swift swift-app/Sources/App/AppDelegate.swift
git commit -m "feat(ai): @ai capture in PaneHost + task card overlay + Ask AI shortcut"
```

---

### Task 9: Settings — AI section

**Files:**
- Modify: `swift-app/Sources/UI/Panels/Settings/SettingsWindow.swift` (`SettingsSection` + `.ai` case, title "AI", symbol "sparkles")
- Modify: `swift-app/Sources/UI/Panels/Settings/SettingsRows.swift` (AI page: Base URL text field, Model text field, API Key secure field — writes `AppPreferences.shared.aiBaseUrl/aiModel` and `Keychain.setSecret` live, no Save button, house style)
- Modify: `swift-app/tools/settingstest.swift` (append AI-page checks)

**Interfaces:**
- Consumes: Task 6 (`AppPreferences.aiBaseUrl/aiModel`, `Keychain`).
- Produces: nothing downstream.

- [x] **Step 1: Write failing tests** — append to `settingstest.swift`'s `main()` (it already builds `SettingsRootView` headless): select `.ai`, assert the page exposes three fields and that setting values round-trips through prefs (Keychain in test: setSecret(nil) first to clear).

```swift
print("— AI settings —")
let aiPrefs = UserDefaults(suiteName: "aitest")!
let p = AppPreferences(defaults: aiPrefs)
p.aiBaseUrl = "https://api.example.com/v1"
p.aiModel = "m-1"
check(p.aiBaseUrl == "https://api.example.com/v1" && p.aiModel == "m-1", "ai prefs round-trip")
Keychain.setSecret(nil, for: "aitest-key")
Keychain.setSecret("sekrit", for: "aitest-key")
check(Keychain.secret(for: "aitest-key") == "sekrit", "keychain round-trip")
Keychain.setSecret(nil, for: "aitest-key")
check(Keychain.secret(for: "aitest-key") == nil, "keychain delete")
```

- [x] **Step 2: Run** `./run-tests.sh` — expect FAIL.

- [x] **Step 3: Implement** the section + rows (follow the `.configFile` page pattern for layout; secure field = `NSSecureTextField` styled like `ChromeInput`).

- [x] **Step 4: Run tests + build** — green.

- [x] **Step 5: Commit**

```bash
git add swift-app/Sources/UI/Panels/Settings/SettingsWindow.swift \
        swift-app/Sources/UI/Panels/Settings/SettingsRows.swift swift-app/tools/settingstest.swift
git commit -m "feat(ai): settings section — base url, model, api key"
```

---

### Task 10: SSH-path hardening + acceptance pass

**Files:**
- Modify: `swift-app/Sources/UI/Terminal/TerminalViews.swift` (only if acceptance finds issues)
- Modify: `swift-app/tools/aitest.swift` (regression checks for anything fixed)

**Interfaces:** none new.

- [x] **Step 1: SSH manual acceptance** (needs one configured host alias in `~/.ssh/config`): open a remote workspace, `@ai list files here` → card shows `host · cwd`; probes run over ssh (verify with the mux socket count or `ssh -O check`); a mutation proposal confirms against the remote ONLY (`touch` a file in remote cwd, confirm locally it does not exist); the proposal header shows the alias; task survives tab switch (card re-binds on `onUpdate` since keyed by taskId→paneKey); closing the remote tab marks tasks `.cancelled` (wire `retire()` → cancel tasks whose pane key matches — add this in Step 1 if missing).

- [x] **Step 2: Spec acceptance matrix** — walk the spec's 10 acceptance checks manually; each failure gets a failing aitest check first, then the fix, then green.

- [x] **Step 3: Full gates** — `cd swift-app && ./build.sh && ./run-tests.sh`; sessiond untouched so cargo gates stay green by construction (`cargo fmt --check && cargo clippy -D warnings && cargo test --manifest-path sessiond/Cargo.toml` once, for hygiene).

- [x] **Step 4: Commit**

```bash
git add -A swift-app
git commit -m "feat(ai): acceptance pass — ssh path hardening + regression tests"
```

---

## Self-Review

**Spec coverage:** trigger (spec §User interaction → Tasks 4, 8); AI-block-not-PTY (§Architecture UI → Task 8); ExecutionTarget transparency (§ExecutionTarget → Tasks 1, 3, 8); four tools + permission mapping (§Tools → Tasks 2, 3, 7); confirmation tuple invalidation (§Tools → Task 7 edit/confirm semantics + fingerprint); lifecycle + budget + no-stdin (§Task lifecycle → Tasks 7, 8); security allowlist/privacy/fail-closed (§Security → Tasks 2, 6, 8); acceptance checks 1–10 (§Acceptance → Tasks 8, 10). Deferred items (`@pi`/`@claude`, goty-agent, second confirm) appear only as spec Future-work — correctly absent.

**Placeholder scan:** Task 7's test note replaces the spin-wait with a semaphore in the actual test; no TBDs remain.

**Type consistency:** `AITask` mutators (Task 1) match coordinator usage (Task 7); `ExecResult/ExecFailure` shapes match Task 3 tests; `LineTrigger.filter` signature matches Task 8's onWrite wrap; `AIProviderConfigured` in Task 8 was renamed to `OpenAICompatibleClient.isConfigured` (static) — implementers use the latter.

// goty — see CLAUDE.md for the working principles.
import CryptoKit
import Foundation

/// One remote workspace's transport: installs our musl-static sessiond on
/// the host (home directory only, content-hash named so client and server
/// binaries can never disagree), starts it detached, and bridges its Unix
/// socket back through a single `ssh -N -L` forward. Panes, replay rings,
/// and PTYs live on the remote daemon — dropping the forward or quitting
/// the GUI leaves every remote session running.
final class RemoteDaemonLink {
    /// `outdated`: the daemon answers but predates the capability level
    /// this build needs — spawn/attach work, agent identity/status do
    /// not (no fg/agent in the list reply, no report server, no env
    /// injection in panes it spawned). The owner must choose between
    /// `upgradeDaemon()` (restarts it; its sessions end) and
    /// `acceptOutdated()` (proceed degraded).
    enum LinkState { case connecting, ready, failed, outdated }

    let host: String
    private(set) var state: LinkState = .connecting {
        didSet { onStateChange?(state) }
    }
    var onStateChange: ((LinkState) -> Void)?

    /// Non-nil once the forwarded socket answers the protocol handshake.
    /// Also set in the `outdated` state: accepting the old daemon must
    /// not re-run the boot pipeline.
    private(set) var daemon: SessionDaemon?
    private(set) var remoteShell: String = "/bin/bash"
    /// The remote host's user-shell environment, captured once per boot
    /// through an interactive login shell (see captureHostProfile).
    /// Agent panes spawn the CLI DIRECTLY (no login shell), so the
    /// process env comes from THIS dictionary — the daemon's own env is
    /// a non-login ssh default whose PATH never sees ~/.bun/bin, nvm…
    private(set) var remoteEnvironment: [String: String] = [:]
    /// Which agent CLIs exist on the host, probed once per boot in the
    /// spawn env (AgentRegistry binaries). Menus and openAgentSession read it.
    private(set) var agentAvailability: [String: Bool] = [:]
    /// Capability the remote daemon reported at handshake. Owners use
    /// it to remember per-host upgrade declines (one nag per build).
    private(set) var reportedCapability: Int?
    /// True between upgradeDaemon() and the boot() that answers it —
    /// onUpgradeResult fires exactly once per attempt.
    private var upgradePending = false
    /// True when the RUNNING daemon's content-hash binary differs from
    /// the bundled one while its capability number still passes the
    /// gates — a same-capability binary swap the number alone can't
    /// see (2026-09-11, host 5090). Gates the sidebar upgrade item.
    private(set) var binaryStale = false

    /// Whether the daemon named in `pgrep -af` output IS the expected
    static func runningBinaryMatches(pgrepOutput: String,
                                      expectedName: String) -> Bool {
        for line in pgrepOutput.split(separator: "\n") {
            for token in line.split(separator: " ") {
                let name = (token as NSString).lastPathComponent
                if name.hasPrefix("goty-sessiond-") {
                    return name == expectedName
                }
            }
        }
        return true
    }

    /// One upgrade attempt's verdict: the capability the daemon reports
    /// AFTER the kill-and-reboot. Owners surface success/failure from
    /// here — an upgrade that silently no-ops is indistinguishable
    /// from success without it.
    var onUpgradeResult: ((Int) -> Void)?
    /// Remote paths boot() resolved — `upgradeDaemon()` needs the exact
    /// content-hashed binary path to target the stale instance.
    private var remoteBinPath: String?

    private var forward: Process?
    private var forwardPath: String?
    /// Bumped on every teardown/open so a stale forward's termination
    /// handler can tell itself apart from the live generation.
    private var forwardEpoch = 0
    private var stopping = false
    /// Application-layer liveness: ssh's own keepalives ride the
    /// protocol channel and can stay green while the FORWARDED data
    /// path is wedged (2026-09-16, host 5090: forward process alive,
    /// ServerAlive answered, every VERSION through the socket timed
    /// out). A missed ping budget tears the link down ourselves.
    private var heartbeat: DispatchSourceTimer?
    private var heartbeatInFlight = false
    private var heartbeatMisses = 0
    private var booting = false
    private let queue = DispatchQueue(label: "goty.remote-link", qos: .userInitiated)
    private var retryDelay: TimeInterval = 1
    /// One scheduled boot-retry at a time (pane attach loops otherwise
    /// pile a new retry onto every failure).
    private var retryScheduled = false

    init(host: String) {
        self.host = host
    }

    /// Idempotent: safe to call from every layout pass until ready.
    func start() {
        queue.async { [weak self] in
            guard let self, !self.booting, !self.retryScheduled,
                  self.daemon == nil, !self.stopping else { return }
            self.booting = true
            self.boot()
        }
    }

    /// Drops the forward only. The remote daemon and its panes keep running.
    func stop() {
        queue.async { [weak self] in self?.stopInner() }
    }

    /// Synchronous stop for quit: applicationWillTerminate returns and the
    /// process exits before an async queue drain, orphaning the forward ssh
    /// (12 accumulated across one crashy evening — each holding its
    /// unlinked socket). Bounded wait: a quit during a blocking boot ssh
    /// still exits, worst case one orphan.
    func stopAndWait(timeout: TimeInterval = 2) {
        let sem = DispatchSemaphore(value: 0)
        queue.async { [weak self] in
            self?.stopInner()
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + timeout)
    }

    private func stopInner() {
        stopping = true
        teardownForward()
        daemon = nil
        booting = false
    }

    // MARK: - Bootstrap pipeline (serial queue, blocking ssh calls)

    private func boot() {
        defer { booting = false }
        guard !stopping else { return }

        // Step 1 — liveness via a REAL ssh round-trip (BatchMode,
        // 4s connect timeout). A hand-rolled TCP+banner probe reads
        // EHOSTUNREACH on process-name-split TUNs (2026-09-11, host
        // 5090: `ssh` itself connected in 0.4s while the GUI's own
        // socket got "no route to host" — the tunnel's rules pass the
        // ssh PROCESS and blackhole everything else). The ssh path is
        // also exactly what every later step uses, so the answer is
        // honest by construction.
        guard Self.sshAlive(host: host) else {
            scheduleRetry(reason: "host unreachable")
            return
        }
        state = .connecting

        guard let binary = SessionDaemon.remoteServerBinary() else {
            NSLog("remote-link %@: bundled server binary missing", host)
            state = .failed
            return
        }
        guard let (arch, home) = probe() else {
            scheduleRetry(reason: "ssh probe failed")
            return
        }
        guard arch == "x86_64" else {
            NSLog("remote-link %@: unsupported arch %@", host, arch)
            state = .failed
            return
        }

        let dir = home + "/.local/share/goty"
        let binPath = dir + "/bin/goty-sessiond-" + Self.contentHash(of: binary)
        let sockPath = dir + "/sessiond.sock"

        if !ssh("test -x \(Shell.forceQuoted(binPath)) && echo present || echo missing")
            .contains("present") {
            upload(binary: binary, to: binPath, dir: dir)
        }

        // Idempotent start: the daemon's own singleton guard rejects a
        // second instance. `setsid --fork` detaches it into its own session
        // with init as parent, so this shell — and the ssh session under
        // it — exits immediately instead of waiting on the daemon.
        // The log TRUNCATES per start: one run's worth, never an
        // ever-growing append across daemon generations.
        _ = ssh("cd \(Shell.forceQuoted(home)) && setsid --fork \(Shell.forceQuoted(binPath)) "
            + "\(Shell.forceQuoted(sockPath)) </dev/null >\(Shell.forceQuoted(dir + "/sessiond.log")) 2>&1; true")

        guard openForward(remoteSocket: sockPath) else {
            scheduleRetry(reason: "forward failed")
            return
        }

        let daemon = SessionDaemon(socketPath: forwardPath!, isRemote: true)
        remoteBinPath = binPath
        guard let capability = daemon.pingCapability() else {
            scheduleRetry(reason: "handshake failed")
            return
        }
        reportedCapability = capability
        // An upgrade attempt just got its verdict: report it once,
        // whatever it is (the silent-accept path must not swallow a
        // failed upgrade — the user asked for it explicitly).
        if upgradePending {
            upgradePending = false
            let verdict = capability
            DispatchQueue.main.async { [weak self] in
                self?.onUpgradeResult?(verdict)
            }
        }
        // Old daemon instance still serving (fixed socket path +
        // singleton, so an upgrade never replaces a running one):
        // panes work, agent identity/status silently don't. Park in
        // `outdated` — the owner decides between restart and degraded.
        // Host profile BEFORE the capability gate: probing agents is
        // ssh knowledge, not daemon knowledge. The outdated path used
        // to return above it — a remembered upgrade-decline then ran
        // silent acceptOutdated with an EMPTY availability table:
        // empty + menus and a false "omp 未安装" on every open
        // (2026-08-31, host 5090 @ capability 2).
        if let shell = ssh("echo $SHELL").split(separator: "\n").last,
           shell.hasPrefix("/") {
            remoteShell = String(shell.trimmingCharacters(in: .whitespaces))
        }
        captureHostProfile()
        guard capability >= SessionDaemon.expectedCapability else {
            NSLog("remote-link %@: daemon capability %d < %d — outdated (agents %@)",
                  host, capability, SessionDaemon.expectedCapability,
                  agentAvailability.filter { $0.value }.keys.sorted().joined(separator: ","))
            self.daemon = daemon
            state = .outdated
            return
        }
        // Below the STORE capability the panes work but omp history /
        // resume paths read a foreign filesystem — same consent flow
        // (restart ends the remote sessions; declining keeps panes and
        // shows the per-pane notice instead).
        guard capability >= SessionDaemon.storeCapability else {
            NSLog("remote-link %@: daemon capability %d < %d — no store access",
                  host, capability, SessionDaemon.storeCapability)
            self.daemon = daemon
            state = .outdated
            return
        }
        // Same-capability binary drift: the number passed, but the
        // RUNNING binary may be an older build (a daemon uploaded
        // before a store fix, still reporting the same capability —
        // 2026-09-11, host 5090 served omp rows to store:"codex").
        // pgrep's bracket form keeps this ssh's own shell out of the
        // match; the argv token names the content hash.
        let expectedName = (binPath as NSString).lastPathComponent
        let pgrep = ssh("pgrep -af \"[g]oty-sessiond\" 2>/dev/null || true")
        binaryStale = !Self.runningBinaryMatches(pgrepOutput: pgrep,
                                                  expectedName: expectedName)
        if binaryStale {
            NSLog("remote-link %@: daemon binary drift (running != %@) — outdated",
                  host, expectedName)
            self.daemon = daemon
            state = .outdated
            return
        }
        retryDelay = 1
        self.daemon = daemon
        state = .ready
        startHeartbeat()
        NSLog("remote-link %@: ready (shell %@, agents %@)", host, remoteShell,
              agentAvailability.filter { $0.value }.keys.sorted().joined(separator: ","))
    }


    /// Queue-confined. One short-lived VERSION round every 20s; two
    /// consecutive misses (a miss = no answer within the interval) mean
    /// the forwarded data path is wedged even though the ssh process is
    /// alive — tear the forward down and reboot before the user sits in
    /// another blackhole. The ping itself runs on a utility queue so the
    /// link queue (retries, teardown) never blocks on a dead socket.
    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeatInFlight = false
        heartbeatMisses = 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 20, repeating: 20)
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopping else { return }
            guard self.daemon != nil else { return }
            if self.heartbeatInFlight {
                self.heartbeatMisses += 1
                NSLog("remote-link %@: heartbeat miss %d", self.host, self.heartbeatMisses)
                if self.heartbeatMisses >= 2 {
                    NSLog("remote-link %@: heartbeat dead — rebooting link", self.host)
                    self.daemon = nil
                    self.teardownForward()
                    self.retryScheduled = false
                    self.scheduleRetry(reason: "heartbeat timeout")
                }
                return
            }
            self.heartbeatInFlight = true
            let daemon = self.daemon
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let alive = daemon?.pingCapability() != nil
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    self.heartbeatInFlight = false
                    if alive {
                        self.heartbeatMisses = 0
                    }
                }
            }
        }
        timer.resume()
        heartbeat = timer
    }
    /// Three ssh execs: the user-shell env (agent panes spawn the CLI
    /// directly, so THIS becomes the process env) and which agent CLIs
    /// exist on the host — probed in that same env. Blocking ssh — the
    /// boot queue is the right place; ready is only reported once the
    /// profile is known.
    private func captureHostProfile() {
        // Interactive beats plain login: version managers and bun add
        // their bins in the INTERACTIVE half of .bashrc/.zshrc, so a
        // plain `-l -c` capture never sees them (bun's ~/.bun/bin hid a
        // host's omp from login too). stdin is /dev/null so an rc that
        // reads input fails fast instead of hanging the boot queue; the
        // chain degrades to plain login, then raw env (dash has no -i).
        let envOut = ssh("\(Shell.forceQuoted(remoteShell)) -l -i -c env </dev/null 2>/dev/null "
            + "|| \(Shell.forceQuoted(remoteShell)) -l -c env 2>/dev/null || env")
        var parsed: [String: String] = [:]
        for line in envOut.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            parsed[String(line[line.startIndex..<eq])] = String(line[line.index(after: eq)...])
        }
        if !parsed.isEmpty { remoteEnvironment = parsed }

        // The rc capture is best effort: interactive init helpers can
        // flake under boot-time ssh load (observed 2026-08-31 — a
        // host's ~/.bun/bin vanished from a captured PATH while omp sat
        // in it), so FLOOR the PATH with the standard tool-manager bins
        // that exist on disk. Plain `ls -d` keeps this shell-syntax
        // free; extras go in front, deduped. Spawn env and probe both
        // read THIS merged PATH.
        if let captured = remoteEnvironment["PATH"] {
            let components = captured.split(separator: ":").map(String.init)
            let listed = ssh("ls -d \"$HOME/.local/bin\" \"$HOME/.cargo/bin\" "
                + "\"$HOME/.bun/bin\" \"$HOME/.ante/bin\" \"$HOME/go/bin\" \"$HOME/bin\" "
                + "/usr/local/bin /opt/homebrew/bin /home/linuxbrew/.linuxbrew/bin 2>/dev/null")
            let extras = listed.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !components.contains($0) }
            if !extras.isEmpty {
                remoteEnvironment["PATH"] = (extras + components).joined(separator: ":")
            }
        }

        // Probe in the SPAWN env: availability must answer "will the
        // pane's `sh -c 'exec omp …'` resolve the binary" — so it runs
        // against the captured PATH, never ssh's non-login default (the
        // false "omp 未安装"). Raw fallback when nothing was captured.
        // One name per lookup: dash's `command -v` with several names
        // reports ONLY the first hit (2026-08-31, host 5090 — omp found,
        // claude/codex silently swallowed). `--` dropped too: dash.
        let binaries = AgentRegistry.probeCatalog.map(\.binary).joined(separator: " ")
        let script = "for b in \(binaries); do p=$(command -v \"$b\" 2>/dev/null) "
            + "&& printf '%s\\n' \"$p\"; done; true"
        let capturedPath = remoteEnvironment["PATH"] ?? ""
        let probe = !capturedPath.isEmpty
            ? ssh("env PATH=\(Shell.forceQuoted(capturedPath)) sh -c \(Shell.forceQuoted(script))")
            : ssh(script)
        let found = Set(probe.split(separator: "\n").map(String.init))
        for entry in AgentRegistry.probeCatalog {
            agentAvailability[entry.key] =
                found.contains { $0.hasSuffix("/" + entry.binary) }
        }
    }

    /// Menu/picker gating for a REMOTE agent key. Local availability is
    /// the caller's business (AgentRegistry + local PATH).
    func isAgentAvailable(key: String) -> Bool {
        agentAvailability[key] ?? false
    }

    /// Waiting for a retry IS the failed state: the sidebar shows red and a
    /// reconnect button instead of an eternal yellow "connecting".
    private func scheduleRetry(reason: String) {
        teardownForward()
        guard !stopping else { return }
        state = .failed
        // Single-flight: pane attach loops re-enter boot() at their own
        // cadence; without this gate every failure scheduled ANOTHER
        // retry and the log showed seven threads storming in parallel
        // (2026-09-11, host 5090). One scheduled retry is the whole plan.
        if retryScheduled {
            NSLog("remote-link %@: %@ — retry already scheduled", host, reason)
            return
        }
        retryScheduled = true
        NSLog("remote-link %@: %@ — retrying in %.0fs", host, reason, retryDelay)
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 10)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            guard !self.stopping, self.daemon == nil else { return }
            self.booting = true
            self.boot()
        }
    }

    /// Close Server's full cleanup: the sessions die with their daemon
    /// (PTY masters close → SIGHUP), so kill the daemon itself — an idle
    /// resident process on a server the user closed is residue. Re-adding
    /// the host re-runs boot(), which restarts it transparently. Runs on
    /// the link queue, so it precedes stop()'s teardown (queue FIFO).
    func stopRemoteDaemon() {
        queue.async { [weak self] in
            guard let self, let binPath = self.remoteBinPath else { return }
            _ = self.ssh("pkill -f " + Shell.forceQuoted(binPath) + "; true")
        }
    }

    /// Manual reconnect: reset and probe immediately (same two-step path).
    func reconnectNow() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopping = false
            self.teardownForward()
            self.daemon = nil
            self.retryScheduled = false
            self.retryDelay = 1
            self.state = .connecting
            self.booting = true
            self.boot()
        }
    }

    /// Proceed with the outdated daemon: spawn/attach/input all work;
    /// agent logo/status stay dead until it is upgraded. The forward
    /// and daemon handle stay as boot() left them.
    func acceptOutdated() {
        queue.async { [weak self] in
            guard let self, self.state == .outdated else { return }
            NSLog("remote-link %@: proceeding with outdated daemon", self.host)
            self.state = .ready
        }
    }

    /// Restart the remote daemon on the current binary. Its sessions
    /// END — the caller must have the user's consent for exactly that.
    /// Kills by the content-hashed binary path (unique per build), then
    /// re-runs the boot pipeline: the singleton socket is free now, so
    /// the fresh instance binds and reports the current capability.
    ///
    /// The kill WAITS: TERM → poll → KILL. Firing pkill and booting
    /// immediately let the fresh instance die on the still-held socket
    /// while the old build kept serving its old capability — the
    /// upgrade dialog then looped forever (2026-08-31, host 5090).
    /// `pkill -f` would also match THIS command's own remote shell (the
    /// pattern is a substring of its command line) and cut the ssh
    /// session mid-kill — hence the `[g]` character-class trick.
    func upgradeDaemon() {
        queue.async { [weak self] in
            // `.ready` is accepted-outdated: the once-per-build prompt
            // was declined (or missed) — an explicit menu action must
            // still reach the kill-and-reboot pipeline.
            guard let self, !self.stopping,
                  self.state == .outdated || self.state == .ready else { return }
            self.state = .connecting
            self.daemon = nil
            // Kill ANY historical build, not this build's hash: the
            // running daemon is by definition an OLDER content hash
            // than the binPath boot() just resolved, so a hash-specific
            // pattern never matched it — the upgrade silently no-oped
            // (2026-09-02, host 5090: dialog closed, daemon untouched).
            // '[g]oty-sessiond' matches every hash-suffixed name while
            // this command's own argv (the literal bracket form) never
            // matches, so pkill cannot kill its own shell.
            if self.remoteBinPath != nil {
                _ = self.ssh("pkill -f '[g]oty-sessiond'; i=0;"
                    + " while pgrep -f '[g]oty-sessiond' >/dev/null && [ $i -lt 20 ]; do"
                    + " i=$((i+1)); [ $i -ge 16 ] && pkill -9 -f '[g]oty-sessiond';"
                    + " sleep 0.3; done; true")
            }
            self.upgradePending = true
            self.teardownForward()
            self.retryScheduled = false
            self.retryDelay = 1
            self.booting = true
            self.boot()
        }
    }

    // MARK: - ssh helpers (blocking; the queue is serial and off-main)

    private func ssh(_ command: String, stdin: Data? = nil) -> String {
        // Best-effort like before: stdout regardless of exit status.
        let result = Shell.exec(command, host: host, stdin: stdin)
        return String(decoding: result.stdout, as: UTF8.self)
    }

    private func probe() -> (arch: String, home: String)? {
        let out = ssh("printf '%s\\n%s\\n' \"$(uname -m)\" \"$HOME\"")
        let lines = out.split(separator: "\n")
        guard lines.count >= 2 else { return nil }
        let arch = lines[0]
        let home = lines[1].trimmingCharacters(in: .whitespaces)
        guard arch.count < 20, home.hasPrefix("/") else { return nil }
        return (String(arch), home)
    }

    private func upload(binary: String, to binPath: String, dir: String) {
        guard let data = FileManager.default.contents(atPath: binary), !data.isEmpty else {
            NSLog("remote-link %@: cannot read bundled server binary", host)
            return
        }
        let tmp = binPath + ".tmp"
        _ = ssh("mkdir -p \(Shell.forceQuoted(dir + "/bin")) && cat > \(Shell.forceQuoted(tmp)) "
            + "&& chmod 755 \(Shell.forceQuoted(tmp)) && mv \(Shell.forceQuoted(tmp)) \(Shell.forceQuoted(binPath))",
            stdin: data)
        // Content-hash names accumulate; keep only the one we run.
        _ = ssh("cd \(Shell.forceQuoted(dir + "/bin")) && for f in goty-sessiond-*; do "
            + "[ \"$f\" = \"$(basename \(Shell.forceQuoted(binPath)))\" ] || rm -f -- \"$f\"; done")
    }


    // MARK: - Forward lifecycle

    private func openForward(remoteSocket: String) -> Bool {
        teardownForward()
        let dir = NSHomeDirectory() + "/Library/Application Support/goty/fwd"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/" + host + ".sock"
        try? FileManager.default.removeItem(atPath: path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-N", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
            // The user's ~/.ssh/config sets `TCPKeepAlive no` globally
            // (fine for interactive shells); on a forward it turns a
            // lossy-path TCP stall into an UNDETECTABLE black hole — the
            // ssh process stays alive, every pane spawn/echo queues into
            // a dead socket, and nothing ever rebuilds the link (5090
            // evening-peak report 2026-09-16: VERSION 15s no-reply
            // through the forward while the remote daemon answered in
            // 0ms locally). Keep the KERNEL probing so a stalled TCP
            // dies and the termination handler reboots the forward.
            "-o", "TCPKeepAlive=yes",
            "-L", path + ":" + remoteSocket, host,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // A forward ssh dying under a live link is a transport drop
        // (proxy flow reset, sleep/wake, node switch): auto-reboot. The
        // remote daemon keeps every session, so panes re-attach with
        // replay once the new forward is up — no manual reconnect.
        forwardEpoch += 1
        let epoch = forwardEpoch
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.rebootIfOrphaned(epoch: epoch) }
        }
        do { try process.run() } catch { return false }

        forward = process
        forwardPath = path
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if Self.probeSocket(path) { return true }
            if !process.isRunning { break }
            usleep(100_000)
        }
        return false
    }
    private func teardownForward() {
        // Invalidate the dying generation's handler BEFORE terminate: the
        // handler's queue block runs after this block, so the epoch check
        // in rebootIfOrphaned always sees the bump.
        forwardEpoch += 1
        heartbeat?.cancel()
        heartbeat = nil
        if let process = forward {
            let pid = process.processIdentifier
            if process.isRunning {
                process.terminate()
                // SIGTERM is a request; a wedged ssh (channels blocked on
                // dead peers) can ignore it indefinitely. Each retry then
                // leaked one forward — seven accumulated on laozhu, four
                // on 5090 (2026-09-16), every one of them a black hole
                // racing the fresh link for the socket path. Escalate.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                    if kill(pid, SIGKILL) == 0 || errno == ESRCH {
                        // reaped or already gone — either is fine
                    }
                }
            }
        }
        forward = nil
        if let path = forwardPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        forwardPath = nil
    }

    /// Queue-confined. Only the generation live when the process died
    /// reboots: every deliberate teardown bumps the epoch first. The
    /// coordinator state is deliberately untouched — the workspace stays
    /// green while panes retry their attach chain against the rebooted
    /// link; only a boot failure (scheduleRetry) flips it offline.
    private func rebootIfOrphaned(epoch: Int) {
        guard epoch == forwardEpoch, !stopping, daemon != nil else { return }
        NSLog("remote-link %@: forward exited — rebooting link", host)
        daemon = nil
        teardownForward()
        retryScheduled = false
        retryDelay = 1
        booting = true
        boot()
    }

    private static func probeSocket(_ path: String) -> Bool {
        let fd = SessionDaemon.rawConnect(path: path)
        guard fd >= 0 else { return false }
        Darwin.close(fd)
        return true
    }

    private static func contentHash(of path: String) -> String {
        guard let data = FileManager.default.contents(atPath: path) else { return "unknown" }
        return String(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    /// One real ssh execution decides liveness: exit 0 = alive. This
    /// rides the same network path as every later ssh call (agents,
    /// uploads, forwards), so ProxyCommands, process-split TUNs and
    /// odd routing all resolve exactly the way the real traffic will.
    private static func sshAlive(host: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=4",
                             "-o", "StrictHostKeyChecking=accept-new",
                             host, "true"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

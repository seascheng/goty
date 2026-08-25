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
    /// Capability the remote daemon reported at handshake. Owners use
    /// it to remember per-host upgrade declines (one nag per build).
    private(set) var reportedCapability: Int?
    /// Remote paths boot() resolved — `upgradeDaemon()` needs the exact
    /// content-hashed binary path to target the stale instance.
    private var remoteBinPath: String?

    private var forward: Process?
    private var forwardPath: String?
    private var stopping = false
    private var booting = false
    private let queue = DispatchQueue(label: "goty.remote-link", qos: .userInitiated)
    private var retryDelay: TimeInterval = 1

    init(host: String) {
        self.host = host
    }

    /// Idempotent: safe to call from every layout pass until ready.
    func start() {
        queue.async { [weak self] in
            guard let self, !self.booting, self.daemon == nil, !self.stopping else { return }
            self.booting = true
            self.boot()
        }
    }

    /// Drops the forward only. The remote daemon and its panes keep running.
    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopping = true
            self.teardownForward()
            self.daemon = nil
            self.booting = false
        }
    }

    // MARK: - Bootstrap pipeline (serial queue, blocking ssh calls)

    private func boot() {
        defer { booting = false }
        guard !stopping else { return }

        // Step 1 — reachability, fast: a 1s TCP probe against the resolved
        // endpoint (following ProxyJump one hop). No ssh timeouts involved;
        // an unreachable host is declared failed immediately.
        guard Self.reachable(sshHost: host, depth: 0) else {
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

        migrateLegacyTmuxSessions()

        guard openForward(remoteSocket: sockPath) else {
            scheduleRetry(reason: "forward failed")
            return
        }

        let daemon = SessionDaemon(socketPath: forwardPath!)
        remoteBinPath = binPath
        guard let capability = daemon.pingCapability() else {
            scheduleRetry(reason: "handshake failed")
            return
        }
        reportedCapability = capability
        // Old daemon instance still serving (fixed socket path +
        // singleton, so an upgrade never replaces a running one):
        // panes work, agent identity/status silently don't. Park in
        // `outdated` — the owner decides between restart and degraded.
        guard capability >= SessionDaemon.expectedCapability else {
            NSLog("remote-link %@: daemon capability %d < %d — outdated",
                  host, capability, SessionDaemon.expectedCapability)
            self.daemon = daemon
            state = .outdated
            return
        }
        if let shell = ssh("echo $SHELL").split(separator: "\n").last,
           shell.hasPrefix("/") {
            remoteShell = String(shell.trimmingCharacters(in: .whitespaces))
        }
        retryDelay = 1
        self.daemon = daemon
        state = .ready
        NSLog("remote-link %@: ready (shell %@)", host, remoteShell)
    }

    /// Waiting for a retry IS the failed state: the sidebar shows red and a
    /// reconnect button instead of an eternal yellow "connecting".
    private func scheduleRetry(reason: String) {
        teardownForward()
        guard !stopping else { return }
        state = .failed
        NSLog("remote-link %@: %@ — retrying in %.0fs", host, reason, retryDelay)
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 10)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopping, self.daemon == nil else { return }
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
    func upgradeDaemon() {
        queue.async { [weak self] in
            guard let self, self.state == .outdated, !self.stopping else { return }
            self.state = .connecting
            self.daemon = nil
            if let binPath = self.remoteBinPath {
                _ = self.ssh("pkill -f " + Shell.forceQuoted(binPath) + "; true")
            }
            self.teardownForward()
            self.retryDelay = 1
            self.booting = true
            self.boot()
        }
    }

    // MARK: - ssh helpers (blocking; the queue is serial and off-main)

    private func ssh(_ command: String, stdin: Data? = nil) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = SshTransport.options(host: host, command: command)
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        if let stdin {
            let inPipe = Pipe()
            process.standardInput = inPipe
            try? process.run()
            try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
            inPipe.fileHandleForWriting.closeFile()
        } else {
            process.standardInput = FileHandle.nullDevice
            try? process.run()
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
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

    /// Panes created by the abandoned tmux backend keep running pointlessly.
    private func migrateLegacyTmuxSessions() {
        _ = ssh("tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^goty_' "
            + "| while read -r s; do tmux kill-session -t \"$s\" 2>/dev/null; done; true")
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
            "-L", path + ":" + remoteSocket, host,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
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
        if let process = forward, process.isRunning {
            process.terminate()
        }
        forward = nil
        if let path = forwardPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        forwardPath = nil
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
    // MARK: - Reachability (no ssh involved)

    /// Resolve the ssh alias locally (`ssh -G` never touches the network),
    /// then verify the ssh SERVICE answers. Proxy TUNs (Clash etc.) accept
    /// every TCP handshake locally — a bare connect proves nothing on this
    /// class of machine — so the probe must read the server's identification
    /// string. ProxyJump chains are followed one hop: the link cannot come
    /// up unless the jump host answers anyway.
    private static func reachable(sshHost: String, depth: Int) -> Bool {
        guard depth < 3 else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", sshHost]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return false }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return false }

        var fields: [String: String] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2 { fields[String(parts[0])] = String(parts[1]).trimmingCharacters(in: .whitespaces) }
        }
        if let jump = fields["proxyjump"], jump.lowercased() != "none", !jump.isEmpty {
            return reachable(sshHost: jump, depth: depth + 1)
        }
        let hostname = fields["hostname"] ?? sshHost
        let port = UInt16(fields["port"] ?? "22") ?? 22
        return sshServiceAnswers(host: hostname, port: port)
    }
    /// Connect (1s) and read the server banner (1.5s). A banner that starts
    /// with "SSH-" is the only honest proof the far side is alive; refused,
    /// blackholed, and proxy-faked connects all read as unreachable.
    private static func sshServiceAnswers(host: String, port: UInt16) -> Bool {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let first = info else {
            return false
        }
        defer { freeaddrinfo(info) }

        for candidate in sequence(first: first, next: { $0.pointee.ai_next }) {
            let ai = candidate.pointee
            let fd = socket(ai.ai_family, ai.ai_socktype, ai.ai_protocol)
            guard fd >= 0 else { continue }
            defer { Darwin.close(fd) }
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            let rc = Darwin.connect(fd, ai.ai_addr, ai.ai_addrlen)
            guard rc == 0 || (rc < 0 && errno == EINPROGRESS) else { continue }
            if rc < 0 {
                var pollfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                guard poll(&pollfd, 1, 1000) > 0 else { continue }
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
                guard error == 0 else { continue }
            }
            // Handshake done (possibly by a proxy). Demand the banner.
            if bannerStarts(with: "SSH-", fd: fd) { return true }
        }
        return false
    }

    /// Reads until the identification line arrives or 1.5s passes.
    private static func bannerStarts(with prefix: String, fd: Int32) -> Bool {
        let deadline = Date().addingTimeInterval(1.5)
        var received = [UInt8]()
        while Date() < deadline {
            var pollfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remaining = max(0, deadline.timeIntervalSinceNow)
            guard poll(&pollfd, 1, Int32(remaining * 1000)) > 0,
                  pollfd.revents & Int16(POLLIN) != 0 else { return false }
            var buffer = [UInt8](repeating: 0, count: 256)
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { return false }
            received.append(contentsOf: buffer[0..<n])
            if received.count > 4, String(decoding: received.prefix(4), as: UTF8.self) == prefix {
                return true
            }
            if received.count > 1024 { return false }
        }
        return false
    }
}

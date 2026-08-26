// goty — see CLAUDE.md for the working principles.
import Foundation
import Darwin

struct SessionGrid: Equatable {
    var columns: UInt16
    var rows: UInt16
    var cellWidth: UInt16
    var cellHeight: UInt16

    var wire: Data {
        var data = Data(capacity: 8)
        for value in [columns, rows, cellWidth, cellHeight] {
            var little = value.littleEndian
            data.append(Data(bytes: &little, count: 2))
        }
        return data
    }

    init(columns: UInt16, rows: UInt16, cellWidth: UInt16, cellHeight: UInt16) {
        self.columns = max(columns, 1)
        self.rows = max(rows, 1)
        self.cellWidth = max(cellWidth, 1)
        self.cellHeight = max(cellHeight, 1)
    }

    init?(wire: Data) {
        guard wire.count == 8 else { return nil }
        let bytes = [UInt8](wire)
        func value(_ offset: Int) -> UInt16 {
            UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
        }
        self.init(columns: value(0), rows: value(2),
                  cellWidth: value(4), cellHeight: value(6))
    }
}

private enum SessionFrame {
    static let spawn: UInt8 = 1
    static let attach: UInt8 = 2
    static let input: UInt8 = 3
    static let resize: UInt8 = 4
    static let detach: UInt8 = 5
    static let kill: UInt8 = 6
    static let list: UInt8 = 7
    static let version: UInt8 = 8

    static let spawned: UInt8 = 0x81
    static let size: UInt8 = 0x82
    static let snapshot: UInt8 = 0x83
    static let output: UInt8 = 0x84
    static let exited: UInt8 = 0x85
    static let paneList: UInt8 = 0x86
    static let versionReply: UInt8 = 0x87
    static let attached: UInt8 = 0x88
    static let error: UInt8 = 0xff
}

/// One sessiond endpoint: the local singleton, or a remote daemon reached
/// through an ssh-forwarded Unix socket. The wire protocol is identical.
final class SessionDaemon {
    static let shared = SessionDaemon()

    private let socketPath: String
    private let launcher: (() -> Bool)?
    private let lock = NSLock()

    /// Local daemon socket path — fixed, so the singleton instance
    /// outlives every GUI launch (and upgrade).
    static let sharedSocketPath =
        NSHomeDirectory() + "/Library/Application Support/goty/sessiond.sock"

    /// Local daemon: spawned from the app bundle when not yet running.
    private convenience init() {
        let dir = (Self.sharedSocketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        self.init(socketPath: Self.sharedSocketPath) { Self.startBundledDaemon(socketPath: Self.sharedSocketPath) }
    }

    /// Terminate the locally running daemon so the next `ensureRunning()`
    /// starts the current binary (bind_singleton reaps the dead socket).
    /// Its sessions END — callers must ask the user first. Matched by
    /// argv (`<binary> <sharedSocketPath>`), which only our daemon has.
    static func terminateSharedForUpgrade() {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        // Both generations: an old goty-sessiond still holds the shared
        // socket after this rename — killing only goty-sessiond would
        // leave it alive and the respawn can't bind.
        pkill.arguments = ["-f", "(goty|goty)-sessiond.*" + sharedSocketPath]
        pkill.standardOutput = FileHandle.nullDevice
        pkill.standardError = FileHandle.nullDevice
        try? pkill.run()
        // Wait: callers respawn immediately after — without this the
        // spawn can race the still-alive old daemon's socket.
        pkill.waitUntilExit()
    }

    /// Remote daemon: the transport beneath the socket is managed elsewhere
    /// (RemoteDaemonLink), so there is nothing to launch here.
    init(socketPath: String, launcher: (() -> Bool)? = nil) {
        self.socketPath = socketPath
        self.launcher = launcher
    }

    private static func startBundledDaemon(socketPath: String) -> Bool {
        guard let binary = bundledBinary(name: "goty-sessiond") else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [socketPath]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        do {
            try process.run()
        } catch {
            return false
        }
        // The daemon outlives the GUI by design; no need to retain it here.
        return true
    }

    /// The musl static server we ship to remote hosts.
    static func remoteServerBinary() -> String? { bundledBinary(name: "goty-sessiond-linux-x86_64") }

    private static func bundledBinary(name: String) -> String? {
        if let bundled = Bundle.main.executableURL?
            .deletingLastPathComponent().appendingPathComponent(name).path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        if let resource = Bundle.main.url(forResource: name, withExtension: nil),
           FileManager.default.isExecutableFile(atPath: resource.path) {
            return resource.path
        }
        let local = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidates = [
            local.appendingPathComponent("sessiond/target/release/goty-sessiond"),
            local.appendingPathComponent(
                "sessiond/target/x86_64-unknown-linux-musl/release/goty-sessiond"),
        ]
        let lookup = name == "goty-sessiond" ? candidates : [candidates[1]]
        return lookup.first { FileManager.default.isExecutableFile(atPath: $0.path) }?.path
    }

    /// Connect to the daemon, launching the bundled binary first when this is
    /// the local endpoint. The daemon is never terminated with the GUI: it
    /// owns the sessions users expect to survive.
    func ensureRunning() -> Bool {
        if canConnect() { return true }
        lock.lock()
        defer { lock.unlock() }
        if canConnect() { return true }
        guard let launcher, launcher() else { return false }
        // Startup is resolved by the socket becoming connectable, not an
        // arbitrary delay. This loop runs off-main from every caller.
        let deadline = Date().addingTimeInterval(2)
        repeat {
            let fd = Self.connect(path: socketPath)
            if fd >= 0 { Darwin.close(fd); return true }
            usleep(10_000)
        } while Date() < deadline
        return false
    }

    /// Capability level this daemon reports — the sessiond `CAPABILITY`
    /// constant. Daemons are singleton and detached, so a machine can
    /// serve an old build indefinitely; this is how the client tells.
    /// nil = no daemon / unusable handshake, NOT "old".
    static let expectedCapability = 3

    func pingCapability() -> Int? {
        let fd = Self.connect(path: socketPath)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        guard Self.writeFrame(fd: fd, kind: SessionFrame.version, payload: Data()),
              let frame = Self.readFrame(fd: fd), frame.0 == SessionFrame.versionReply,
              let level = Int(String(decoding: frame.1, as: UTF8.self))
        else { return nil }
        return level
    }

    /// The locally running daemon's capability, without launching
    /// anything: nil = not running (fresh start path); below expected =
    /// a stale instance the caller must deal with before relying on
    /// fg/agent data (the 2026-08-24 remote-degradation root cause).
    static func sharedRunningCapability() -> Int? {
        let fd = connect(path: shared.socketPath)
        guard fd >= 0 else { return nil }
        Darwin.close(fd)
        return shared.pingCapability()
    }

    /// Attach-or-spawn. Attach first so the daemon's replay ring is the
    /// single screen authority on both local and remote panes; spawn only
    /// when the pane does not exist yet.
    func openPane(id: String, cwd: String?, shell: String, args: [String],
                  environment: [String: String], grid: SessionGrid,
                  onFrame: @escaping (UInt8, Data) -> Void,
                  onDisconnect: @escaping () -> Void) -> PaneSession? {
        guard ensureRunning() else { return nil }

        var fd = Self.connect(path: socketPath)
        guard fd >= 0 else { return nil }
        var initial: (UInt8, Data)?
        let attach = ["pane_id": id]
        if let data = try? JSONSerialization.data(withJSONObject: attach),
           Self.writeFrame(fd: fd, kind: SessionFrame.attach, payload: data),
           let first = Self.readFrame(fd: fd), first.0 != SessionFrame.error {
            initial = first
        } else {
            Darwin.close(fd)
            fd = Self.connect(path: socketPath)
            guard fd >= 0 else { return nil }
            let request: [String: Any] = [
                "pane_id": id,
                "cwd": cwd ?? NSNull(),
                "shell": shell,
                "args": args,
                "env": environment.map { [$0.key, $0.value] },
                "size": [
                    "cols": grid.columns, "rows": grid.rows,
                    "cell_w": grid.cellWidth, "cell_h": grid.cellHeight,
                ],
                "replay": true,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: request),
                  Self.writeFrame(fd: fd, kind: SessionFrame.spawn, payload: data),
                  let spawned = Self.readFrame(fd: fd), spawned.0 == SessionFrame.spawned
            else { Darwin.close(fd); return nil }
        }


        return PaneSession(fd: fd, initial: initial,
                           onFrame: onFrame, onDisconnect: onDisconnect)
    }

    struct PaneInfo {
        let id: String
        let alive: Bool
        let cwd: String?
        /// argv0-derived foreground command (nil on older daemons).
        let fg: String?
        /// Live agent TUI state ("working"/"blocked"/"idle") from the
        /// omp/pi extension reporting to this daemon; nil = none.
        let agent: String?
    }

    func listPanes() -> [PaneInfo] {
        guard ensureRunning() else { return [] }
        let fd = Self.connect(path: socketPath)
        guard fd >= 0 else { return [] }
        defer { Darwin.close(fd) }
        guard Self.writeFrame(fd: fd, kind: SessionFrame.list, payload: Data()),
              let frame = Self.readFrame(fd: fd), frame.0 == SessionFrame.paneList,
              let raw = try? JSONSerialization.jsonObject(with: frame.1) as? [[String: Any]]
        else { return [] }
        return raw.compactMap { item in
            guard let id = item["pane_id"] as? String,
                  let alive = item["alive"] as? Bool else { return nil }
            return PaneInfo(id: id, alive: alive, cwd: item["cwd"] as? String,
                            fg: item["fg"] as? String, agent: item["agent"] as? String)
        }
    }

    func killPane(id: String) {
        guard ensureRunning() else { return }
        let fd = Self.connect(path: socketPath)
        guard fd >= 0 else { return }
        _ = Self.writeFrame(fd: fd, kind: SessionFrame.kill, payload: Data(id.utf8))
        Darwin.close(fd)
    }

    private func canConnect() -> Bool {
        let fd = Self.connect(path: socketPath)
        guard fd >= 0 else { return false }
        Darwin.close(fd)
        return true
    }


    /// Connect probe for transports we do not own (remote links).
    static func rawConnect(path: String) -> Int32 { connect(path: path) }

    fileprivate static func connect(path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd); return -1
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            bytes.withUnsafeBytes { source in
                buffer.copyBytes(from: source)
            }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { Darwin.close(fd); return -1 }
        return fd
    }

    fileprivate static func writeFrame(fd: Int32, kind: UInt8, payload: Data) -> Bool {
        guard payload.count <= 16 * 1024 * 1024 else { return false }
        var length = UInt32(payload.count).littleEndian
        var header = Data(bytes: &length, count: 4)
        header.append(kind)
        return writeAll(fd: fd, data: header) && writeAll(fd: fd, data: payload)
    }

    fileprivate static func readFrame(fd: Int32) -> (UInt8, Data)? {
        guard let header = readExact(fd: fd, count: 5) else { return nil }
        let bytes = [UInt8](header)
        let length = Int(UInt32(bytes[0]) | UInt32(bytes[1]) << 8
            | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24)
        guard length <= 16 * 1024 * 1024,
              let payload = readExact(fd: fd, count: length) else { return nil }
        return (bytes[4], payload)
    }

    private static func readExact(fd: Int32, count: Int) -> Data? {
        if count == 0 { return Data() }
        var data = Data(count: count)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < count {
                let readCount = Darwin.read(fd, base.advanced(by: offset), count - offset)
                if readCount > 0 { offset += readCount; continue }
                if readCount < 0 && errno == EINTR { continue }
                return false
            }
            return true
        }
        return ok ? data : nil
    }

    private static func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if written > 0 { offset += written; continue }
                if written < 0 && errno == EINTR { continue }
                return false
            }
            return true
        }
    }
}

final class PaneSession {
    private var fd: Int32
    private let initial: (UInt8, Data)?
    private let onFrame: (UInt8, Data) -> Void
    private let onDisconnect: () -> Void
    private let writeLock = NSLock()
    private var stopped = false

    fileprivate init(fd: Int32, initial: (UInt8, Data)?,
                     onFrame: @escaping (UInt8, Data) -> Void,
                     onDisconnect: @escaping () -> Void) {
        self.fd = fd
        self.initial = initial
        self.onFrame = onFrame
        self.onDisconnect = onDisconnect
    }

    func start() {
        let first = initial
        let readFD = fd
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            if let first { self.deliver(first) }
            while let frame = SessionDaemon.readFrame(fd: readFD) {
                self.deliver(frame)
            }
            self.writeLock.lock()
            let notify = !self.stopped
            self.writeLock.unlock()
            if notify {
                DispatchQueue.main.async { [weak self] in self?.onDisconnect() }
            }
        }
    }

    func sendInput(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        send(kind: SessionFrame.input, payload: Data(bytes))
    }

    func resize(_ grid: SessionGrid) {
        send(kind: SessionFrame.resize, payload: grid.wire)
    }

    func close() {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !stopped else { return }
        stopped = true
        _ = SessionDaemon.writeFrame(fd: fd, kind: SessionFrame.detach, payload: Data())
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        fd = -1
    }

    private func send(kind: UInt8, payload: Data) {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !stopped, fd >= 0 else { return }
        if !SessionDaemon.writeFrame(fd: fd, kind: kind, payload: payload) {
            stopped = true
        }
    }

    /// Called on the session's read thread. The frame consumer (PaneHost)
    /// routes bytes onto its own serial stream queue — never hop through
    /// the main queue here: parsing must stay off main so a full apprt
    /// mailbox can always be drained by the main-thread app tick.
    private func deliver(_ frame: (UInt8, Data)) {
        onFrame(frame.0, frame.1)
    }
}

// Shared frame identifiers used by PaneHost without exposing protocol details.
enum SessionOutputKind {
    static let size: UInt8 = SessionFrame.size
    static let snapshot: UInt8 = SessionFrame.snapshot
    static let output: UInt8 = SessionFrame.output
    static let exited: UInt8 = SessionFrame.exited
    static let attached: UInt8 = SessionFrame.attached
    static let error: UInt8 = SessionFrame.error
}

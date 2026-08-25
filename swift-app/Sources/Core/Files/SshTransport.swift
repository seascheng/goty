// goty — see CLAUDE.md for the working principles.
import Foundation

// MARK: - ssh transport options

/// Connection options every ssh exec in the app runs with. Beyond the
/// proven BatchMode/ConnectTimeout pair, all execs multiplex through one
/// ControlMaster per host: the first connection authenticates, everything
/// after it — directory listings included — reuses the established session
/// with no handshake. That reuse is most of what makes this faster than
/// scp, which pays a fresh connection per invocation.
enum SshTransport {
    /// Control-socket prefix. `%C` is ssh's hash of user/host/port, so
    /// one socket per host, named deterministically. Lives under ~/.ssh
    /// (created if missing) — ssh's `-o` parser splits option values on
    /// spaces, so the path must be space-free (not Application Support),
    /// and ControlPath must stay under ~104 bytes.
    private static var controlPrefix: String {
        let dir = NSHomeDirectory() + "/.ssh/goty-mux"
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
        return dir + "/%C"
    }

    static var muxOptions: [String] {
        ["-o", "ControlMaster=auto",
         "-o", "ControlPath=\(controlPrefix)",
         "-o", "ControlPersist=10m"]
    }

    /// The full option set for an exec: fast-fail plus multiplexing.
    static func options(host: String, command: String) -> [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"] + muxOptions + [host, command]
    }
}

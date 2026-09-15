// goty — see CLAUDE.md for the working principles.
import Foundation
@testable import goty

/// Daemon transport throughput probe: spawn a plain terminal pane on a
/// (probe) daemon, flood it with `ls <dir>` output, and measure
/// end-to-end MB/s through PaneSession — the same path the GUI uses.
/// Usage: termbench <dir-to-ls> [socket-path]
@main
enum TermBench {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            fputs("usage: termbench <dir> [socket]\n", stderr)
            exit(2)
        }
        let dir = args[1]
        let socket = args.count > 2 ? args[2]
            : NSHomeDirectory() + "/Library/Application Support/goty/sessiond.sock"
        let daemon = SessionDaemon(socketPath: socket, launcher: nil)

        let grid = SessionGrid(columns: 200, rows: 50, cellWidth: 8, cellHeight: 16)
        let paneId = "termbench-\(Int(Date().timeIntervalSince1970 * 1000))"
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var totalBytes = 0
        var done = false
        let t0 = Date()

        guard let session = daemon.openPane(
            id: paneId, cwd: "/tmp", shell: "/bin/zsh", args: [],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            grid: grid, noEcho: true,
            onFrame: { kind, data in
                guard kind == SessionOutputKind.output else { return }
                lock.lock(); totalBytes += data.count; lock.unlock()
                if data.range(of: Data("DONE_42".utf8)) != nil {
                    lock.lock()
                    if !done { done = true; semaphore.signal() }
                    lock.unlock()
                }
            },
            onDisconnect: {
                lock.lock()
                if !done { done = true; semaphore.signal() }
                lock.unlock()
            }) else {
            fputs("termbench: openPane failed\n", stderr)
            exit(1)
        }
        session.start()
        session.sendInput(Array("ls \(dir); echo DONE_$((41+1))\n".utf8))

        _ = semaphore.wait(timeout: .now() + 60)
        Thread.sleep(forTimeInterval: 0.2)   // drain the tail
        lock.lock(); let bytes = totalBytes; lock.unlock()
        let seconds = Date().timeIntervalSince(t0)
        // Cleanup: kill the pane, then close our session.
        daemon.killPane(id: paneId)
        session.close()

        let mib = Double(bytes) / 1_048_576
        print(String(format: "termbench bytes=%d seconds=%.2f mib_per_second=%.2f",
                     bytes, seconds, mib / max(seconds, 0.001)))
    }
}

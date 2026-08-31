// goty — see CLAUDE.md for the working principles.
import Foundation

// MARK: - Shell helpers

/// Shell-quoting shared by the terminal-insert path and remote file ops.
/// One implementation, one truth (was duplicated in three call sites).
enum Shell {
    /// A path that is safe to paste into a shell command line: quoted
    /// only when it needs to be (spaces or embedded quotes).
    static func quotedPath(_ path: String) -> String {
        guard path.contains(" ") || path.contains("'") else { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Always single-quoted (for embedding inside a remote command).
    static func forceQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Join argv into one command line (quoting every element).
    static func join(_ argv: [String]) -> String {
        argv.map(forceQuoted).joined(separator: " ")
    }

    /// True for nil (a spawned shell) and the plain shell basenames —
    /// matches what sessiond's foreground report spells at a prompt.
    /// Lives here (Core) so the workspace coordinator can gate on it
    /// without touching the UI layer's PaneHost.
    static func isShellPromptCommand(_ command: String?) -> Bool {
        guard let command, !command.isEmpty else { return true }
        var base = (command as NSString).lastPathComponent
        if base.hasPrefix("-") { base = String(base.dropFirst()) }
        return ["zsh", "bash", "sh", "fish", "dash", "ash"].contains(base)
    }

    /// THE process-execution seam: run one command locally (`/bin/sh -c`)
    /// or remotely (`ssh <host> <command>`), blocking, and collect
    /// stdout/stderr/exit status. Six near-identical hand-rolled
    /// Process+Pipe blocks used to live across GitStatus/FileSources/
    /// RemoteDaemonLink/UserShellEnv — every new caller must go through
    /// here. Blocking; call off the main thread.
    static func exec(_ command: String, host: String? = nil,
                     stdin: Data? = nil) -> (code: Int32, stdout: Data, stderr: String) {
        let proc = Process()
        if let host {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = SshTransport.options(host: host, command: command)
        } else {
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = ["-c", command]
        }
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        if stdin != nil {
            let inPipe = Pipe()
            proc.standardInput = inPipe
            do { try proc.run() } catch {
                return (-1, Data(), "could not run \(host != nil ? "ssh" : "/bin/sh"): \(error.localizedDescription)")
            }
            // A failed stdin pipe means the payload never arrived — a
            // silent truncation must not read as success (remote writes).
            do {
                try inPipe.fileHandleForWriting.write(contentsOf: stdin!)
                try inPipe.fileHandleForWriting.close()
            } catch {
                proc.terminate()
                proc.waitUntilExit()
                return (-1, Data(), "stdin write failed: \(error.localizedDescription)")
            }
        } else {
            do { try proc.run() } catch {
                return (-1, Data(), "could not run \(host != nil ? "ssh" : "/bin/sh"): \(error.localizedDescription)")
            }
        }
        // Read BEFORE waiting on exit — past the pipe buffer a chatty
        // child blocks on write and would deadlock a wait-first order.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
        proc.waitUntilExit()
        return (proc.terminationStatus, data, errText)
    }
}

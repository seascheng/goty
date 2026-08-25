// goty — see CLAUDE.md for the working principles.
import Foundation

// MARK: - Remote (ssh) execution

/// Executes commands on a remote host via /usr/bin/ssh with the same
/// transport options the remote file sources use (BatchMode fast-fail,
/// ControlMaster mux reuse). Write pipes content through stdin; edit is
/// a client-side read → replace → write round trip.
final class SSHExecutor: CommandExecutor {
    let host: String

    init(host: String) {
        self.host = host
    }

    private func sshRun(_ command: String, stdin: Data?, timeout: TimeInterval,
                        completion: @escaping (Result<ExecResult, ExecFailure>) -> Void) {
        ProcessRunner.run(
            argv: ["/usr/bin/ssh"] + SshTransport.options(host: host, command: command),
            cwd: nil, env: nil, stdin: stdin, timeout: timeout, completion: completion)
    }

    func run(_ command: String, cwd: String?, timeout: TimeInterval,
             completion: @escaping (Result<ExecResult, ExecFailure>) -> Void) {
        let full = cwd != nil
            ? "cd \(Shell.forceQuoted(cwd!)) && \(command)"
            : command
        sshRun(full, stdin: nil, timeout: timeout, completion: completion)
    }

    func read(path: String, completion: @escaping (Result<String, ExecFailure>) -> Void) {
        sshRun("cat -- \(Shell.forceQuoted(path))", stdin: nil, timeout: 30) { r in
            switch r {
            case .success(let e): completion(.success(e.stdout))
            case .failure(let f): completion(.failure(f))
            }
        }
    }

    func write(path: String, content: String,
               completion: @escaping (Result<ExecResult, ExecFailure>) -> Void) {
        sshRun("cat > \(Shell.forceQuoted(path))", stdin: Data(content.utf8),
               timeout: 30, completion: completion)
    }

    func edit(path: String, oldText: String, newText: String,
              completion: @escaping (Result<ExecResult, ExecFailure>) -> Void) {
        read(path: path) { r in
            switch r {
            case .failure(let f):
                completion(.failure(f))
            case .success(let body):
                guard let range = body.range(of: oldText) else {
                    completion(.failure(.editAnchorNotFound))
                    return
                }
                var updated = body
                updated.replaceSubrange(range, with: newText)
                self.write(path: path, content: updated, completion: completion)
            }
        }
    }
}

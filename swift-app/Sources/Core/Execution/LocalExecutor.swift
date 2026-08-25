// goty — see CLAUDE.md for the working principles.
import Foundation

// MARK: - Local execution

/// Short-lived-process runner shared by the AI executors: argv + env +
/// optional stdin, with a deadline timer that SIGTERMs on timeout.
/// Pipes are drained concurrently with waitUntilExit so output larger
/// than the pipe buffer cannot deadlock.
enum ProcessRunner {
    static func run(argv: [String], cwd: String?, env: [String: String]?,
                    stdin: Data?, timeout: TimeInterval,
                    completion: @escaping (Result<ExecResult, ExecFailure>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: argv[0])
            p.arguments = Array(argv.dropFirst())
            if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            if let env { p.environment = env }
            let outPipe = Pipe()
            let errPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = errPipe
            if let stdin {
                let inPipe = Pipe()
                p.standardInput = inPipe
                do { try p.run() } catch {
                    completion(.failure(.spawnFailed(error.localizedDescription)))
                    return
                }
                inPipe.fileHandleForWriting.write(stdin)
                inPipe.fileHandleForWriting.closeFile()
            } else {
                do { try p.run() } catch {
                    completion(.failure(.spawnFailed(error.localizedDescription)))
                    return
                }
            }

            var outData = Data()
            var errData = Data()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }

            let timer = DispatchSource.makeTimerSource()
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler { if p.isRunning { p.terminate() } }
            timer.resume()

            p.waitUntilExit()
            timer.cancel()
            group.wait()

            // Our deadline is the only SIGTERM source in these flows.
            if p.terminationReason == .uncaughtSignal && p.terminationStatus == SIGTERM {
                completion(.failure(.timeout))
                return
            }
            completion(.success(ExecResult(
                exitCode: p.terminationStatus,
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? "")))
        }
    }
}

/// Executes commands on the local machine through /bin/zsh with the
/// user's interactive shell environment (same env the panes see).
final class LocalExecutor: CommandExecutor {
    func run(_ command: String, cwd: String?, timeout: TimeInterval,
             completion: @escaping (Result<ExecResult, ExecFailure>) -> Void) {
        ProcessRunner.run(argv: ["/bin/zsh", "-c", command], cwd: cwd,
                          env: UserShellEnv.asDictionary, stdin: nil,
                          timeout: timeout, completion: completion)
    }

    func read(path: String, completion: @escaping (Result<String, ExecFailure>) -> Void) {
        run("cat -- \(Shell.forceQuoted(path))", cwd: nil, timeout: 10) { r in
            switch r {
            case .success(let e): completion(.success(e.stdout))
            case .failure(let f): completion(.failure(f))
            }
        }
    }

    func write(path: String, content: String,
               completion: @escaping (Result<ExecResult, ExecFailure>) -> Void) {
        ProcessRunner.run(argv: ["/bin/zsh", "-c", "cat > \(Shell.forceQuoted(path))"],
                          cwd: nil, env: UserShellEnv.asDictionary,
                          stdin: Data(content.utf8), timeout: 10, completion: completion)
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

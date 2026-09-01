// goty — see CLAUDE.md for the working principles.
import Foundation

// MARK: - Local execution

/// Cancellation handle for one spawned process. Cancel-before-spawn is
/// remembered so the process dies the moment it attaches.
final class ProcessRunnerHandle {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        let p = process
        lock.unlock()
        // terminate() on an exited Process is a no-op; SIGTERM is
        // interpreted as `.timeout` by the runner's exit check.
        if p?.isRunning == true { p?.terminate() }
    }

    fileprivate func attach(_ p: Process) {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { p.terminate(); return }
        process = p
    }
}

/// Short-lived-process runner shared by the AI executors: argv + env +
/// optional stdin, with a deadline timer that SIGTERMs on timeout.
/// Pipes are drained concurrently with waitUntilExit so output larger
/// than the pipe buffer cannot deadlock. Captured output is CAPPED
/// (the pipe keeps draining past the cap — the child must never block
/// on us) so a command dumping gigabytes cannot balloon memory.
enum ProcessRunner {
    /// Per-stream capture ceiling; past it bytes are drained, not kept.
    private static let maxCapture = 8 * 1024 * 1024

    @discardableResult
    static func run(argv: [String], cwd: String?, env: [String: String]?,
                    stdin: Data?, timeout: TimeInterval,
                    completion: @escaping (Result<ExecResult, ExecFailure>) -> Void)
            -> ProcessRunnerHandle {
        let handle = ProcessRunnerHandle()
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
            handle.attach(p)

            var outData = Data()
            var errData = Data()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                outData = Self.drainCapped(outPipe.fileHandleForReading)
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                errData = Self.drainCapped(errPipe.fileHandleForReading)
                group.leave()
            }

            let timer = DispatchSource.makeTimerSource()
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler { if p.isRunning { p.terminate() } }
            timer.resume()

            p.waitUntilExit()
            timer.cancel()
            group.wait()

            // Our deadline and cancellation are the only SIGTERM
            // sources in these flows.
            if p.terminationReason == .uncaughtSignal && p.terminationStatus == SIGTERM {
                completion(.failure(.timeout))
                return
            }
            completion(.success(ExecResult(
                exitCode: p.terminationStatus,
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? "")))
        }
        return handle
    }

    /// Read until EOF, KEEPING at most `maxCapture` bytes. Draining
    /// never stops — a full pipe would block the child.
    private static func drainCapped(_ handle: FileHandle) -> Data {
        var data = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { return data }
            if data.count < maxCapture { data.append(chunk) }
        }
    }
}

/// Executes commands on the local machine through /bin/zsh with the
/// user's interactive shell environment (same env the panes see).
final class LocalExecutor: CommandExecutor {
    @discardableResult
    func run(_ command: String, cwd: String?, timeout: TimeInterval,
             completion: @escaping (Result<ExecResult, ExecFailure>) -> Void)
            -> ProcessRunnerHandle {
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

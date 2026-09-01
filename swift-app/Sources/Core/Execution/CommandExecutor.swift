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
    /// Run a command; the handle cancels the underlying process.
    @discardableResult
    func run(_ command: String, cwd: String?, timeout: TimeInterval,
             completion: @escaping (Result<ExecResult, ExecFailure>) -> Void)
            -> ProcessRunnerHandle
    func read(path: String, completion: @escaping (Result<String, ExecFailure>) -> Void)
    func write(path: String, content: String,
               completion: @escaping (Result<ExecResult, ExecFailure>) -> Void)
    func edit(path: String, oldText: String, newText: String,
              completion: @escaping (Result<ExecResult, ExecFailure>) -> Void)
}

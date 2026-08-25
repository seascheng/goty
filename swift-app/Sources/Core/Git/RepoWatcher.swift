// goty — see CLAUDE.md for the working principles.
import Foundation
import CoreServices

// MARK: - Local repo watcher (FSEvents — the event source git polling lacked)

/// Watches LOCAL repository roots and pushes change notifications.
///
/// Polling inventory (2026-08-23): the app polls exactly what has no
/// push source — the shell's cwd (no OSC 7 without shell integration;
/// tty7 polls 500ms for the same reason), remote repos over ssh exec,
/// and the daemon's foreground list. Local repo state is the one input
/// the kernel CAN push: file-system events. This watcher replaces the
/// time-based git refetch for local repos — an unchanged repo costs
/// zero git executions; a change drops the stores' TTL, so the next
/// 2s tick refetches (freshness preserved, exec only on change).
///
/// FSEvents coalesces within `latency`, so a build storm is one
/// invalidation per window. All state main-thread only; the stream is
/// dispatched to the main queue (a modal session or menu tracking
/// merely delays delivery — it never re-enters anything).
final class RepoWatcher {
    static let shared = RepoWatcher()

    /// Root path → fired. Set once by the composition root; the stores
    /// never register handlers on each other.
    var onRootChanged: ((String) -> Void)?

    private var streams: [String: FSEventStreamRef] = [:]
    /// 0.4s: prompt delivery, and FSEvents' own coalescing window.
    private let latency: TimeInterval = 0.4

    /// Idempotent per root; streams live for the process (a session
    /// visits a handful of repos — no teardown machinery to build).
    func watch(_ root: String) {
        guard streams[root] == nil, !root.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let flags: FSEventStreamCreateFlags =
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
            | FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
            | FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, eventPaths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<RepoWatcher>.fromOpaque(info).takeUnretainedValue()
                watcher.rootChanged(count: count, eventPaths: eventPaths)
            },
            &context,
            [root as CFString] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        streams[root] = stream
    }

    /// Map event paths back to the root they belong to. FileEvents (not
    /// directory-level) is not optional: overwriting a file changes no
    /// directory entry, and content edits are the signal git status
    /// exists to reflect.
    private func rootChanged(count: Int, eventPaths: UnsafeMutableRawPointer) {
        let paths = unsafeBitCast(eventPaths, to: NSArray.self)
        for case let path as String in paths.prefix(count) {
            for root in streams.keys where path == root || path.hasPrefix(root + "/") {
                onRootChanged?(root)
                break
            }
        }
    }
}

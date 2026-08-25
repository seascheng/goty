// goty — see CLAUDE.md for the working principles.
import Foundation

// MARK: - File sources (local + ssh remote, one protocol)

/// A directory listing provider. The Files panel is agnostic to WHERE
/// the files live: a local workspace lists via FileManager, a remote
/// workspace lists via the same BatchMode ssh transport the rest of the
/// app uses. Both produce the same entries, sorted identically.
protocol FileSource {
    var isRemote: Bool { get }
    /// Immediate (blocking) listing — call off the main thread.
    func entries(at path: String) throws -> [FileEntry]
    /// Mutations (blocking, off-main). Names are validated by the caller.
    func createFile(name: String, in dir: String) throws
    func createFolder(name: String, in dir: String) throws
    func delete(_ entry: FileEntry, at dir: String) throws
    /// Move/rename (blocking, off-main). Absolute paths, `mv` semantics:
    /// rename within a directory or relocate across them.
    func move(from: String, to: String) throws
    // Editor surface (blocking, off-main): size+mtime probe, content
    // in/out. The editor's open guards (4 MB, binary sniff) and its
    // changed-on-disk detection are built on these.
    func stat(_ path: String) throws -> FileStat
    func read(_ path: String) throws -> Data
    func write(_ data: Data, to path: String) throws
}

/// What the editor needs to know about a file's disk state.
struct FileStat: Equatable {
    let size: Int64
    let modified: Date
}

/// tty7 code_editor rules: past this the file is refused rather than
/// opened badly, and a NUL in the first 8 KB means binary.
enum EditorFileGuards {
    static let maxBytes: Int64 = 4 * 1024 * 1024

    static func looksBinary(_ data: Data) -> Bool {
        data.prefix(8192).contains(0)
    }
}

/// tty7 classify_external_change, verbatim semantics. A probe that
/// failed (`observed == nil`) is NOT "unchanged": the event already
/// fired, so something moved — clean buffers reload, dirty ones conflict.
enum EditorExternalChange: Equatable {
    case ignore, conflict, reload

    static func classify(saving: Bool, dirty: Bool,
                         diskMtime: Date?, observed: Date?) -> EditorExternalChange {
        if saving { return .ignore }
        if let observed, observed == diskMtime { return .ignore }
        return dirty ? .conflict : .reload
    }
}

struct FileEntry: Equatable {
    let name: String
    let isDirectory: Bool

    /// tty7 order: directories first, then case-insensitive names.
    static func sorted(_ list: [FileEntry]) -> [FileEntry] {
        list.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

/// Filesystem of the machine this app runs on.
struct LocalFileSource: FileSource {
    let isRemote = false

    func entries(at path: String) throws -> [FileEntry] {
        let urls = try FileManager.default.contentsOfDirectory(atPath: path)
        return FileEntry.sorted(urls.filter { $0 != "." && $0 != ".." }.map { name in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: path + "/" + name,
                                           isDirectory: &isDir)
            return FileEntry(name: name, isDirectory: isDir.boolValue)
        })
    }

    func createFile(name: String, in dir: String) throws {
        try Data().write(to: URL(fileURLWithPath: dir + "/" + name))
    }

    func createFolder(name: String, in dir: String) throws {
        try FileManager.default.createDirectory(atPath: dir + "/" + name,
                                                withIntermediateDirectories: false)
    }

    func delete(_ entry: FileEntry, at dir: String) throws {
        try FileManager.default.removeItem(atPath: dir + "/" + entry.name)
    }

    func move(from: String, to: String) throws {
        try FileManager.default.moveItem(atPath: from, toPath: to)
    }


    func stat(_ path: String) throws -> FileStat {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let size = attrs[.size] as? Int64 ?? 0
        let modified = attrs[.modificationDate] as? Date ?? .distantPast
        return FileStat(size: size, modified: modified)
    }

    func read(_ path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }

    func write(_ data: Data, to path: String) throws {
        try data.write(to: URL(fileURLWithPath: path))
    }
}

/// Filesystem of an ssh host. One exec per listing — cheap, stateless,
/// and it reuses the connection options the control client proved work
/// (BatchMode so a dead host fails fast instead of prompting).
struct RemoteFileSource: FileSource {
    let host: String
    var isRemote: Bool { true }

    func entries(at path: String) throws -> [FileEntry] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = SshTransport.options(host: host,
                                               command: "ls -1Ap \(shellQuoted(path))")
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()   // noise stays out of the panel
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw CocoaError(.fileReadUnknown, userInfo: [
                NSLocalizedDescriptionKey: "ssh \(host): exit \(proc.terminationStatus)"])
        }
        let text = String(decoding: data, as: UTF8.self)
        return FileEntry.sorted(text.split(separator: "\n").compactMap { line in
            let name = String(line)
            guard !name.isEmpty else { return nil }
            // -p marks directories with a trailing slash.
            if name.hasSuffix("/") {
                return FileEntry(name: String(name.dropLast()), isDirectory: true)
            }
            return FileEntry(name: name, isDirectory: false)
        })
    }

    private func shellQuoted(_ path: String) -> String {
        Shell.forceQuoted(path)
    }

    /// One ssh exec; non-zero exit surfaces as an error. `stdin` (when
    /// set) is piped in — the whole basis of remote file WRITE without
    /// hitting argv size limits.
    private func execData(_ command: String, stdin: Data? = nil) throws -> Data {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = SshTransport.options(host: host, command: command)
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        let inPipe = Pipe()
        if stdin != nil {
            proc.standardInput = inPipe
        }
        try proc.run()
        if let stdin {
            try inPipe.fileHandleForWriting.write(contentsOf: stdin)
            try inPipe.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw CocoaError(.fileReadUnknown, userInfo: [
                NSLocalizedDescriptionKey: "ssh \(host): exit \(proc.terminationStatus)"])
        }
        return data
    }

    private func exec(_ command: String) throws {
        _ = try execData(command)
    }

    func createFile(name: String, in dir: String) throws {
        try exec("touch \(shellQuoted(dir + "/" + name))")
    }

    func createFolder(name: String, in dir: String) throws {
        try exec("mkdir \(shellQuoted(dir + "/" + name))")
    }

    func delete(_ entry: FileEntry, at dir: String) throws {
        let target = shellQuoted(dir + "/" + entry.name)
        try exec(entry.isDirectory ? "rm -rf \(target)" : "rm -f \(target)")
    }

    func move(from: String, to: String) throws {
        try exec("mv \(shellQuoted(from)) \(shellQuoted(to))")
    }




    /// GNU stat first (Linux remotes), BSD stat as fallback — "size mtime".
    func stat(_ path: String) throws -> FileStat {
        let target = shellQuoted(path)
        let out = try execData("(stat -c '%s %Y' -- \(target) || stat -f '%z %m' -- \(target)) 2>/dev/null")
        let text = String(decoding: out, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.split(separator: " ")
        guard parts.count == 2, let size = Int64(parts[0]),
              let epoch = TimeInterval(parts[1]) else {
            throw CocoaError(.fileReadUnknown, userInfo: [
                NSLocalizedDescriptionKey: "stat: unparsable output"])
        }
        return FileStat(size: size, modified: Date(timeIntervalSince1970: epoch))
    }

    func read(_ path: String) throws -> Data {
        try execData("cat -- \(shellQuoted(path))")
    }

    func write(_ data: Data, to path: String) throws {
        _ = try execData("cat > \(shellQuoted(path))", stdin: data)
    }
}

enum FileSources {
    /// The listing provider for a workspace's machine.
    static func source(for workspace: WorkspaceState) -> FileSource {
        if let host = workspace.sshHost, workspace.isRemote {
            return RemoteFileSource(host: host)
        }
        return LocalFileSource()
    }
}

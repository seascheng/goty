// goty — see CLAUDE.md for the working principles.
import Foundation

/// Workspace file listing for the composer's `@` references.
///
/// Uses ONE `git ls-files` spawn instead of a recursive directory walk:
/// macOS TCC protects ~/Downloads ~/Documents ~/Desktop, and walking a
/// repo there triggers one permission dialog PER directory. A single
/// git process reads the index in one shot. Non-git roots outside the
/// protected zones fall back to a capped BFS; inside them we return
/// nothing rather than nag the user. Results are cached per root.
enum AgentFileIndex {
    private static var cache: [String: [String]] = [:]
    private static let maxFiles = 2000
    private static let maxDepth = 6
    private static let skipDirectories: Set<String> = [
        "node_modules", "build", "dist", "target", ".build", "DerivedData",
        "__pycache__", ".venv", "venv", "Pods",
    ]

    /// Remote roots ride the ssh transport (same ControlMaster mux as
    /// every other remote exec). Non-git remote roots return nothing —
    /// a capped BFS over ssh per keystroke is not a trade worth making.
    static func list(root: String, host: String? = nil) -> [String] {
        let key = (host ?? "") + "::" + root
        if let cached = cache[key] { return cached }
        let files: [String]
        if let host {
            files = remoteGitLSFiles(root: root, host: host) ?? []
        } else {
            files = gitLSFiles(root: root) ?? bfs(root: root)
        }
        cache[key] = files
        return files
    }

    private static func remoteGitLSFiles(root: String, host: String) -> [String]? {
        let result = Shell.exec(
            "git -C \(Shell.forceQuoted(root)) ls-files -co --exclude-standard",
            host: host)
        guard result.code == 0 else { return nil }
        return String(decoding: result.stdout, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func gitLSFiles(root: String) -> [String]? {
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", root, "ls-files", "-co", "--exclude-standard"]
        git.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        git.standardOutput = pipe
        do { try git.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        git.waitUntilExit()
        guard git.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func bfs(root: String) -> [String] {
        // TCC-protected zones: walking here spams permission dialogs.
        let home = NSHomeDirectory()
        if ["Downloads", "Documents", "Desktop"].contains(where: {
            root.hasPrefix(home + "/\($0)/")
        }) { return [] }
        var results: [String] = []
        let baseURL = URL(fileURLWithPath: root)
        var queue: [(url: URL, depth: Int)] = [(baseURL, 0)]
        while !queue.isEmpty, results.count < maxFiles {
            let (dir, depth) = queue.removeFirst()
            if depth > maxDepth { continue }
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
            for item in contents {
                let name = item.lastPathComponent
                if name.hasPrefix(".") { continue }
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory)
                if isDirectory.boolValue {
                    if skipDirectories.contains(name) { continue }
                    queue.append((item, depth + 1))
                } else {
                    let relative = item.path.replacingOccurrences(of: root + "/", with: "")
                    if !relative.isEmpty { results.append(relative) }
                    if results.count >= maxFiles { break }
                }
            }
        }
        return results.sorted()
    }
}

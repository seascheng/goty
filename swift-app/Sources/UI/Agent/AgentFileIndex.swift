// goty — see CLAUDE.md for the working principles.
import Foundation

/// Workspace file listing for the composer's `@` references. Enumerates
/// the session cwd breadth-first, skipping noisy directories (VCS,
/// build output, dependencies) and capping the result — good enough for
/// autocomplete, not a full index.
enum AgentFileIndex {
    private static let skipDirectories: Set<String> = [
        ".git", ".hg", ".svn", "node_modules", ".gradle", "build", "dist",
        "target", ".build", "DerivedData", ".idea", ".vscode", ".next",
        "__pycache__", ".venv", "venv", "Pods", ".DS_Store", "vendor",
    ]
    private static let maxFiles = 2000
    private static let maxDepth = 6

    /// Relative paths of files under `root`. Falls back to an empty list
    /// for remote panes (cwd not on this machine).
    static func list(root: String) -> [String] {
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
                if name.hasPrefix(".") && name != ".env.example" { continue }
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

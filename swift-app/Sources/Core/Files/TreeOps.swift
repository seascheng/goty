// goty — see CLAUDE.md for the working principles.
import Foundation

// MARK: - Files module: pure tree-mutation logic (no AppKit)

/// Decisions about moving entries inside the tree, extracted from the
/// view: the rules are testable without a window, and the view only
/// executes what this plans (UI/logic separation, CLAUDE.md).
enum TreeOps {
    /// Why a move is refused outright (quietly — nothing happened).
    enum Refusal: Error, Equatable {
        case intoItself
        case alreadyThere
    }

    struct Plan {
        /// Moves to run, in order: (from, to).
        let moves: [(from: String, to: String)]
        /// Destination names that already exist — the caller asks
        /// before replacing (nothing is dropped silently).
        let conflicts: [String]
    }

    /// Validate a same-source drag-and-move.
    /// - Parameters:
    ///   - paths: dragged absolute paths.
    ///   - dir: destination directory (folder row itself / file row's
    ///     parent / the tree root).
    ///   - existing: the destination's current entries, for conflict
    ///     detection (nil = unknown listing, conflicts unlisted).
    static func planMove(paths: [String], into dir: String,
                         existing: [FileEntry]?) -> Result<Plan, Refusal> {
        var moves: [(String, String)] = []
        for path in paths {
            // Moving a directory into itself or a descendant is a no-op
            // that would eat the tree — refuse.
            if path == dir || dir.hasPrefix(path + "/") {
                return .failure(.intoItself)
            }
            let parent = (path as NSString).deletingLastPathComponent
            if parent == dir {
                return .failure(.alreadyThere)
            }
            moves.append((path, dir + "/" + (path as NSString).lastPathComponent))
        }
        let taken = Set(existing?.map({ $0.name }) ?? [])
        let conflicts = moves.map { ($0.1 as NSString).lastPathComponent }
            .filter { taken.contains($0) }
        return .success(Plan(moves: moves, conflicts: conflicts))
    }

    /// A renamed/moved directory's expanded-set keys move with it.
    static func rekeyedExpanded(_ expanded: Set<String>, from: String, to: String) -> Set<String> {
        var out = expanded
        for key in expanded where key == from || key.hasPrefix(from + "/") {
            out.remove(key)
            out.insert(to + String(key.dropFirst(from.count)))
        }
        return out
    }
}

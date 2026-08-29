// goty — see CLAUDE.md for the working principles.
import Foundation

/// ACP tool payload shapes drift between flat and nested on the wire
/// (both observed inside one omp 18.0.8 resume replay):
///
/// - flat:    `{"type":"text","text":…}`
/// - nested:  `{"type":"content","content":{"type":"text","text":…}}`
///            (the same wrapper also around an array of leaves)
///
/// Tool results additionally ride `rawOutput.content` — plus omp's
/// `rawOutput.details.displayContent` — which a flat-only reader
/// silently dropped: the missing tool output in resumed transcripts.
enum ACPContentNormalizer {
    /// Depth-first flatten: unwrap `content` wrappers until leaf items
    /// (those carrying text/path) remain, in wire order.
    static func flatten(_ raw: [[String: Any]]?) -> [AgentContent] {
        var out: [AgentContent] = []
        for item in raw ?? [] {
            flatten(item, into: &out)
        }
        return out
    }

    /// Tool-result extraction: `rawOutput.content` leaves; falls back to
    /// omp's `rawOutput.details.displayContent` when the content list is
    /// absent or empty.
    static func resultItems(rawOutput: Any?) -> [AgentContent] {
        guard let ro = rawOutput as? [String: Any] else { return [] }
        let leaves = flatten(ro["content"] as? [[String: Any]])
        if !leaves.isEmpty { return leaves }
        if let details = ro["details"] as? [String: Any],
           let display = details["displayContent"] as? String {
            return [AgentContent(type: "text", text: display, path: nil)]
        }
        return []
    }

    private static func flatten(_ item: [String: Any], into out: inout [AgentContent]) {
        // Leaf first: anything carrying text/path is a leaf regardless of
        // its `type` tag; wrappers recurse into their `content` field.
        if item["text"] is String || item["path"] is String, let leaf = AgentContent(item) {
            out.append(leaf)
            return
        }
        switch item["content"] {
        case let nested as [String: Any]:
            flatten(nested, into: &out)
        case let nested as [[String: Any]]:
            for child in nested {
                flatten(child, into: &out)
            }
        default:
            break
        }
    }
}

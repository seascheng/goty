// goty — see CLAUDE.md for the working principles.
import Foundation

// MARK: - goty's own ghostty config (surgical key edits, pure)

/// The ghostty config goty OWNS (`~/Library/Application Support/
/// goty/ghostty/config`, seeded once from the user's live Ghostty by
/// AppDelegate). Settings edits ONE key at a time and must never
/// disturb hand edits — comments, unknown keys, spacing stay
/// byte-identical (the SSHConfigDocument discipline).
enum GhosttyConfigLine {
    /// `key = value` in any spacing; key compared lowercased.
    case key(String, String, String)
    /// Blank, comment, or anything without a top-level `=`.
    case other(String)

    static func parse(_ raw: String) -> GhosttyConfigLine {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
              let eq = trimmed.firstIndex(of: "=")
        else { return .other(raw) }
        let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return .other(raw) }
        let value = trimmed[trimmed.index(after: eq)...]
            .trimmingCharacters(in: .whitespaces)
        return .key(key, value, raw)
    }
}

struct GhosttyConfigDocument {
    private(set) var lines: [GhosttyConfigLine]

    init(text: String) {
        lines = text.isEmpty ? [] : text.split(separator: "\n",
                                               omittingEmptySubsequences: false)
            .map { GhosttyConfigLine.parse(String($0)) }
    }

    /// Byte-identical to the input while unedited (any trailing
    /// newline convention included).
    var rendered: String {
        lines.map { line -> String in
            switch line {
            case .key(_, _, let text), .other(let text): return text
            }
        }.joined(separator: "\n")
    }

    /// First occurrence wins (ghostty: the first set of a key applies).
    func value(_ key: String) -> String? {
        for line in lines {
            if case .key(let k, let v, _) = line, k == key { return v }
        }
        return nil
    }

    /// Upsert: rewrites the FIRST occurrence in place, drops later
    /// duplicates (first-wins semantics would resurrect them), and
    /// appends at EOF when the key is new.
    mutating func set(_ key: String, _ value: String) {
        var result: [GhosttyConfigLine] = []
        var done = false
        for line in lines {
            guard case .key(let k, _, _) = line, k == key else {
                result.append(line)
                continue
            }
            if !done {
                result.append(.key(key, value, "\(key) = \(value)"))
                done = true
            }
        }
        if !done { result.append(.key(key, value, "\(key) = \(value)")) }
        lines = result
    }

    /// Back to the ghostty default: every occurrence of the key goes.
    mutating func remove(_ key: String) {
        lines = lines.filter {
            if case .key(let k, _, _) = $0 { return k != key }
            return true
        }
    }
}

// MARK: - goty's shipped appearance defaults

/// The Appearance configuration goty ships with — the project's
/// current Settings ▸ Appearance values. AppDelegate seeds these into
/// a config that doesn't exist yet (filling only keys the source
/// doesn't set, so explicit user choices always win), Settings paints
/// them wherever nothing resolves, and Chrome's fallback theme carries
/// the palette. One source for "what goty looks like out of the box".
enum GhosttyConfigDefaults {
    static let theme = "Arthur"
    static let fontFamily = "Maple Mono NF CN"
    static let fontSize = 14.5
    static let backgroundOpacity = 0.80
    static let backgroundBlur = 25.0

    /// `key = value` pairs in Settings ▸ Appearance order.
    static let appearance: [(key: String, value: String)] = [
        ("theme", theme),
        ("font-family", fontFamily),
        ("font-size", String(fontSize)),
        ("background-opacity", String(format: "%.2f", backgroundOpacity)),
        ("background-blur", String(Int(backgroundBlur))),
    ]

    static func value(_ key: String) -> String? {
        appearance.first(where: { $0.key == key })?.value
    }

    static func double(_ key: String) -> Double? {
        value(key).flatMap(Double.init)
    }
}

extension GhosttyConfigDocument {
    /// Upsert every appearance default the document doesn't set yet.
    /// True when anything was written (the caller decides to save).
    @discardableResult
    mutating func fillAppearanceDefaults() -> Bool {
        var touched = false
        for (key, value) in GhosttyConfigDefaults.appearance
        where self.value(key) == nil {
            set(key, value)
            touched = true
        }
        return touched
    }
}

/// Thin load/save for the one config file. Atomic writes only — a
/// half-written config is a broken terminal on next launch.
struct GhosttyConfigStore {
    /// The one path (AppDelegate seeds it; libghostty reads it).
    static let path = NSHomeDirectory()
        + "/Library/Application Support/goty/ghostty/config"

    let url: URL

    init(url: URL = URL(fileURLWithPath: GhosttyConfigStore.path)) {
        self.url = url
    }

    /// Missing/unreadable file → empty document (first write creates it).
    func load() -> GhosttyConfigDocument {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return GhosttyConfigDocument(text: "")
        }
        return GhosttyConfigDocument(text: text)
    }

    func save(_ document: GhosttyConfigDocument) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        guard let data = document.rendered.data(using: .utf8) else { return }
        try data.write(to: url, options: .atomic)
    }
}

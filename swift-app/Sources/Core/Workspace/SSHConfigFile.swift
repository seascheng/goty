// goty — see CLAUDE.md for the working principles.
import Foundation

// MARK: - ~/.ssh/config (tty7-style import + surgical editing, pure)

/// One parsed line of an ssh config file. Every case keeps the VERBATIM
/// source line: untouched lines re-render byte-identical, so editing one
/// stanza never disturbs the rest of the file (comments, Match blocks,
/// unknown keywords included).
enum SSHConfigLine {
    /// `Host alias…` — opens a stanza.
    case host(aliases: [String], text: String)
    /// `Keyword value` (HostName, User, Port, ProxyJump, Match…).
    case keyword(key: String, value: String, text: String)
    /// Blank line or comment.
    case other(String)

    var text: String {
        switch self {
        case .host(_, let text), .keyword(_, _, let text), .other(let text):
            return text
        }
    }

    static func parse(_ raw: String) -> SSHConfigLine {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
              let sep = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" })
        else { return .other(raw) }
        let key = String(trimmed[..<sep]).lowercased()
        let value = trimmed[trimmed.index(after: sep)...]
            .trimmingCharacters(in: .whitespaces)
        if key == "host" {
            let aliases = value.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
            return .host(aliases: aliases, text: raw)
        }
        return .keyword(key: key, value: value, text: raw)
    }
}

/// The whole file as an editable line list. Mutations are SURGICAL:
/// they splice only the touched stanza's lines and leave everything
/// else verbatim.
struct SSHConfigDocument {
    private(set) var lines: [SSHConfigLine]

    init(text: String) {
        lines = text.isEmpty ? [] : text.split(separator: "\n",
                                               omittingEmptySubsequences: false)
            .map { SSHConfigLine.parse(String($0)) }
    }

    /// Byte-identical to the input while unedited (for any trailing
    /// newline convention).
    var rendered: String {
        lines.map(\.text).joined(separator: "\n")
    }

    // MARK: Stanzas

    /// The fields the manager UI edits; everything else passes through.
    private static let managedKeys = ["hostname", "user", "port"]
    private static let canonicalName = ["hostname": "HostName", "user": "User", "port": "Port"]

    struct Stanza {
        var aliases: [String]
        var hostName: String?
        var user: String?
        var port: String?
    }

    /// host line index ..< next Host/Match line (or EOF). `Match` closes
    /// the stanza above it (openssh semantics: a Match block runs until
    /// the next Match or Host line), so its keywords are never part of
    /// a stanza an edit could touch.
    private struct StanzaRange {
        let host: Int
        var end: Int
    }

    private var stanzaRanges: [StanzaRange] {
        var result: [StanzaRange] = []
        for (i, line) in lines.enumerated() {
            switch line {
            case .host:
                if let last = result.indices.last { result[last].end = i }
                result.append(StanzaRange(host: i, end: lines.count))
            case .keyword(let key, _, _) where key == "match":
                if let last = result.indices.last, result[last].end == lines.count {
                    result[last].end = i
                }
            default:
                break
            }
        }
        return result
    }

    var stanzas: [Stanza] {
        stanzaRanges.map { r in
            var stanza = Stanza(aliases: [], hostName: nil, user: nil, port: nil)
            guard case .host(let aliases, _) = lines[r.host] else { fatalError("range starts at Host") }
            stanza.aliases = aliases
            for line in lines[(r.host + 1)..<r.end] {
                guard case .keyword(let key, let value, _) = line else { continue }
                switch key {
                case "hostname" where stanza.hostName == nil: stanza.hostName = value
                case "user" where stanza.user == nil: stanza.user = value
                case "port" where stanza.port == nil: stanza.port = value
                default: break
                }
            }
            return stanza
        }
    }

    /// Picker inventory: every alias, wildcard patterns excluded,
    /// order preserved, deduped.
    var inventoryAliases: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for stanza in stanzas {
            for alias in stanza.aliases {
                if alias.contains("*") || alias.contains("?") || alias.contains("!") { continue }
                if seen.insert(alias).inserted { result.append(alias) }
            }
        }
        return result
    }

    // MARK: Editing

    enum EditError: Error, CustomStringConvertible {
        case noAlias
        case badAlias(String)
        case badPort(String)

        var description: String {
            switch self {
            case .noAlias:
                return "A host needs at least one alias."
            case .badAlias(let a):
                return "\"\(a)\" is not a valid alias."
            case .badPort(let p):
                return "Port \"\(p)\" is not 1–65535."
            }
        }
    }

    /// Validated before any mutation: the document is unchanged when an
    /// edit is rejected.
    static func validate(aliases: [String], port: String?) throws {
        let cleaned = aliases.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { throw EditError.noAlias }
        for alias in cleaned {
            if alias.hasPrefix("-") || alias.contains("#") {
                throw EditError.badAlias(alias)
            }
        }
        if let port, !port.isEmpty {
            guard port.allSatisfy(\.isNumber), let n = Int(port), (1...65_535).contains(n) else {
                throw EditError.badPort(port)
            }
        }
    }

    /// Appends a stanza at the end of the file (one blank separator line
    /// when the file isn't empty).
    mutating func addHost(aliases: [String], hostName: String?, user: String?, port: String?) throws {
        try Self.validate(aliases: aliases, port: port)
        let values = ["hostname": hostName ?? "", "user": user ?? "", "port": port ?? ""]
        if !lines.isEmpty {
            let lastIsBlank: Bool
            if case .other(let t) = lines.last {
                lastIsBlank = t.trimmingCharacters(in: .whitespaces).isEmpty
            } else {
                lastIsBlank = false
            }
            if !lastIsBlank { lines.append(.other("")) }
        }
        lines.append(.host(aliases: aliases, text: "Host " + aliases.joined(separator: " ")))
        for key in Self.managedKeys {
            if let v = values[key], !v.isEmpty {
                lines.append(.keyword(key: key, value: v,
                                      text: "  \(Self.canonicalName[key]!) \(v)"))
            }
        }
    }

    /// Rewrites ONLY the stanza's Host line and managed-keyword lines;
    /// every other line of the stanza (comments, ProxyJump, …) and the
    /// whole rest of the file stay verbatim. Duplicate managed keywords
    /// collapse to one — ssh reads the first occurrence, so keeping the
    /// duplicates would resurrect a stale value.
    mutating func updateHost(_ index: Int, aliases: [String],
                             hostName: String?, user: String?, port: String?) throws {
        try Self.validate(aliases: aliases, port: port)
        let ranges = stanzaRanges
        guard ranges.indices.contains(index) else { return }
        let r = ranges[index]

        let values = ["hostname": hostName ?? "", "user": user ?? "", "port": port ?? ""]
        var body: [SSHConfigLine] = []
        var emitted = Set<String>()
        for line in lines[(r.host + 1)..<r.end] {
            if case .keyword(let key, _, _) = line, Self.managedKeys.contains(key) {
                if !emitted.contains(key), let v = values[key], !v.isEmpty {
                    body.append(.keyword(key: key, value: v,
                                         text: "  \(Self.canonicalName[key]!) \(v)"))
                    emitted.insert(key)
                }
            } else {
                body.append(line)
            }
        }
        // Managed keys with a value but no existing line go right under
        // the Host line, canonical order.
        for key in Self.managedKeys where !emitted.contains(key) {
            if let v = values[key], !v.isEmpty {
                body.insert(.keyword(key: key, value: v,
                                     text: "  \(Self.canonicalName[key]!) \(v)"),
                            at: body.startIndex)
            }
        }
        if case .host(let current, _) = lines[r.host], current != aliases {
            lines[r.host] = .host(aliases: aliases,
                                  text: "Host " + aliases.joined(separator: " "))
        }
        lines.replaceSubrange((r.host + 1)..<r.end, with: body)
    }

    /// Removes the stanza's lines; one blank separator line is kept
    /// between the neighbors (inserted only if both sides lost theirs).
    mutating func removeHost(_ index: Int) {
        let ranges = stanzaRanges
        guard ranges.indices.contains(index) else { return }
        let r = ranges[index]
        lines.removeSubrange(r.host..<r.end)
        if r.host > 0, r.host < lines.count,
           case .other(let prev) = lines[r.host - 1],
           !prev.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.insert(.other(""), at: r.host)
        }
    }
}

// MARK: - File I/O

/// Thin load/save for one ssh config file. Creating the file also
/// creates ~/.ssh (0700) and forces config perms to 0600 — ssh refuses
/// group/world-writable configs, so this is not cosmetic.
struct SSHConfigStore {
    let url: URL

    init(url: URL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh/config")) {
        self.url = url
    }

    /// Missing/unreadable file → empty document (add flow creates it).
    func load() -> SSHConfigDocument {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return SSHConfigDocument(text: "")
        }
        return SSHConfigDocument(text: text)
    }

    func save(_ document: SSHConfigDocument) throws {
        let dir = url.deletingLastPathComponent()
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        guard let data = document.rendered.data(using: .utf8) else { return }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: url.path)
    }
}

// MARK: - Sidebar picker inventory

/// ~/.ssh/config host inventory (tty7-style import). Re-reads only when
/// the file's mtime changed, so the Servers '+' menu is always fresh
/// after the manager (or any editor) writes the file.
enum SSHConfig {
    private static var cache: (mtime: Date, hosts: [String])?

    static func hosts() -> [String] {
        let path = NSHomeDirectory() + "/.ssh/config"
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let mtime = attrs?[.modificationDate] as? Date ?? .distantPast
        if let c = cache, c.mtime == mtime { return c.hosts }
        let hosts = SSHConfigDocument(
            text: (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        ).inventoryAliases
        cache = (mtime, hosts)
        return hosts
    }
}

// goty — see CLAUDE.md for the working principles.
//
// Passive agent-state detection — three cooperating layers:
//   AgentOscTracker     (OSC 0/2 title + OSC 9 capture, incremental)
//   AgentDetect         (rules, regions, arbitration)
//   AgentStatusTracker  (debounce + publish)
//
// Everything here is a pure observer over bytes we already receive and text
// we already render. Nothing is installed into agents, nothing changes the
// sessiond protocol — the same code path serves local and remote panes.
import Foundation

// MARK: - Model

/// Agent state: what the pane looks like right now.
enum AgentActivity: Equatable {
    case idle
    case working
    case blocked
    /// GUI agent panes only: the session died / never attached. The
    /// screen detector never emits it — a terminal running an agent CLI
    /// has no trustworthy "error" signal on glass.
    case error
    case unknown

    var label: String {
        switch self {
        case .idle: return "idle"
        case .working: return "working"
        case .blocked: return "needs input"
        case .error: return "error"
        case .unknown: return "—"
        }
    }

    /// Wire string from the omp/pi extension's socket report.
    init?(_ raw: String) {
        switch raw {
        case "working": self = .working
        case "blocked": self = .blocked
        case "idle": self = .idle
        default: return nil
        }
    }
}

// MARK: - OSC capture

/// Incremental scanner over the pane's output stream. Retains the latest
/// OSC 0/2 title (an empty payload clears it) and the latest OSC 9 payload
/// (the part after `9;`, e.g. `"4;0;"`). Sequences may straddle chunk
/// boundaries; unknown sequences and oversized bodies are skipped safely.
final class AgentOscTracker {
    /// Payload cap — title text is untrusted model output (cap 256).
    private static let maxChars = 256
    /// OSC body cap before the rest of the string is discarded (cap 1KB).
    private static let maxBody = 1024

    private enum State {
        case ground, escape
        case body
        case bodyEscape
        case ignoringString, ignoringStringEscape
        case discarding, discardingEscape
    }
    private var state: State = .ground
    private var body: [UInt8] = []
    /// goty: observe() runs on the pane's stream queue while the
    /// 300ms detect tick reads title/progress on main — one lock covers
    /// the whole tracker (the byte loop stays allocation-free).
    private let lock = NSLock()

    private var _title = ""
    private var _progress = ""
    var title: String { lock.lock(); defer { lock.unlock() }; return _title }
    var progress: String { lock.lock(); defer { lock.unlock() }; return _progress }

    /// Feed one output chunk (replay and live alike — replay restores state).
    /// Stream-queue confined by the caller.
    func observe(_ bytes: UnsafeBufferPointer<UInt8>) {
        lock.lock()
        defer { lock.unlock() }
        for b in bytes {
            switch state {
            case .ground:
                if b == 0x1b { state = .escape }
            case .escape:
                switch b {
                case 0x5d: body.removeAll(keepingCapacity: true); state = .body   // ]
                case 0x50, 0x5f, 0x5e, 0x58: state = .ignoringString               // P _ ^ X
                case 0x1b: break
                default: state = .ground
                }
            case .body:
                switch b {
                case 0x07: finishBody(); state = .ground
                case 0x1b: state = .bodyEscape
                default: pushBody(b)
                }
            case .bodyEscape:
                // ESC \ ends the string; a bare ESC inside the body is data.
                switch b {
                case 0x5c: finishBody(); state = .ground                          // backslash
                case 0x07: finishBody(); state = .ground
                case 0x1b: pushBody(0x1b)
                default: pushBody(0x1b); pushBody(b)
                }
            case .ignoringString:
                if b == 0x1b { state = .ignoringStringEscape }
            case .ignoringStringEscape:
                if b == 0x5c { state = .ground } else if b != 0x1b { state = .ignoringString }
            case .discarding:
                switch b {
                case 0x07: state = .ground
                case 0x1b: state = .discardingEscape
                default: break
                }
            case .discardingEscape:
                if b == 0x5c { state = .ground } else if b != 0x1b { state = .discarding }
            }
        }
    }

    func observe(_ data: Data) {
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                observe(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self),
                                            count: raw.count))
            }
        }
    }

    /// Drops retained evidence (a fresh attach must not inherit the previous
    /// session's title/progress semantics).
    func clearRetained() {
        lock.lock()
        defer { lock.unlock() }
        _title = ""
        _progress = ""
    }

    private func pushBody(_ b: UInt8) {
        body.append(b)
        if body.count > Self.maxBody {
            body.removeAll(keepingCapacity: true)
            state = .discarding
        }
    }

    private func finishBody() {
        defer { body.removeAll(keepingCapacity: true) }
        guard let sep = body.firstIndex(of: 0x3b) else { return }
        let command = body[..<sep]
        let payload = body[body.index(after: sep)...]
        switch command {
        case [0x30], [0x32]: _title = sanitize(payload)
        case [0x39]: _progress = sanitize(payload)
        default: break
        }
    }

    /// Lossy UTF-8 sanitize: control chars dropped,
    /// capped at `maxChars` characters.
    private func sanitize(_ payload: ArraySlice<UInt8>) -> String {
        var out = String()
        out.reserveCapacity(min(payload.count, Self.maxChars))
        for scalar in String(decoding: payload, as: UTF8.self).unicodeScalars
        where scalar.properties.generalCategory != .control {
            out.unicodeScalars.append(scalar)
            if out.unicodeScalars.count >= Self.maxChars { break }
        }
        return out
    }
}

// MARK: - Manifest engine

struct AgentMatchGate {
    var contains: [String] = []
    var regex: [String] = []
    var lineRegex: [String] = []
    var all: [AgentMatchGate] = []
    var any: [AgentMatchGate] = []
    var not: [AgentMatchGate] = []
}

struct AgentManifestRule {
    let id: String
    let state: AgentActivity
    let priority: Int
    let region: String
    var visibleIdle = false
    var visibleBlocker = false
    var visibleWorking = false
    var skipStateUpdate = false
    let gate: AgentMatchGate
}

struct AgentScreenDetection {
    var state: AgentActivity = .unknown
    var skipStateUpdate = false
    var visibleIdle = false
    var visibleBlocker = false
    var visibleWorking = false
}

/// One compiled rule set per agent, built once from `agentManifestTable`.
final class AgentRuleSet {
    private struct CompiledGate {
        let contains: [String]          // needles lowercased
        let regex: [NSRegularExpression]
        let lineRegex: [NSRegularExpression]
        let all: [CompiledGate]
        let any: [CompiledGate]
        let not: [CompiledGate]

        func matches(_ text: String, _ lower: String) -> Bool {
            if contains.contains(where: { !lower.contains($0) }) { return false }
            for regex in regex {
                if regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil {
                    return false
                }
            }
            for regex in lineRegex {
                let anyLine = text.split(separator: "\n", omittingEmptySubsequences: false)
                    .contains { line in
                        regex.firstMatch(in: String(line),
                                         range: NSRange(line.startIndex..., in: line)) != nil
                    }
                if !anyLine { return false }
            }
            if all.contains(where: { !$0.matches(text, lower) }) { return false }
            if !any.isEmpty && !any.contains(where: { $0.matches(text, lower) }) { return false }
            if not.contains(where: { $0.matches(text, lower) }) { return false }
            return true
        }
    }

    private struct CompiledRule {
        let rule: AgentManifestRule
        let gate: CompiledGate
    }

    private let compiled: [CompiledRule]

    init?(rules: [AgentManifestRule]) {
        guard !rules.isEmpty else { return nil }
        // A pattern that fails to compile under ICU is dropped (upstream is
        // Rust regex); a gate that loses its last positive matcher cannot
        // match anything and is dropped with it.
        let compiled = rules.compactMap { rule -> CompiledRule? in
            guard let gate = Self.compileGate(rule.gate) else { return nil }
            return CompiledRule(rule: rule, gate: gate)
        }
        guard !compiled.isEmpty else { return nil }
        self.compiled = compiled
    }

    private static func compileGate(_ gate: AgentMatchGate) -> CompiledGate? {
        let regexes = gate.regex.compactMap { try? NSRegularExpression(pattern: $0) }
        let lineRegexes = gate.lineRegex.compactMap { try? NSRegularExpression(pattern: $0) }
        let hadPositive = !gate.contains.isEmpty || !gate.regex.isEmpty || !gate.lineRegex.isEmpty
        let hasPositive = !gate.contains.isEmpty || !regexes.isEmpty || !lineRegexes.isEmpty
        let subAll = gate.all.compactMap { compileGate($0) }
        let subAny = gate.any.compactMap { compileGate($0) }
        let subNot = gate.not.compactMap { compileGate($0) }
        if hadPositive && !hasPositive { return nil }
        if !hadPositive && subAll.isEmpty && subAny.isEmpty {
            // No positive matcher anywhere (and any/not alone can't match):
            // Rejected at validation time.
            return nil
        }
        return CompiledGate(
            contains: gate.contains.map { $0.lowercased() },
            regex: regexes,
            lineRegex: lineRegexes,
            all: subAll,
            any: subAny,
            not: subNot)
    }

    func detect(screen: String, title: String, progress: String) -> AgentScreenDetection {
        var matched: CompiledRule?
        for c in compiled {
            let region = AgentDetect.region(c.rule.region, screen: screen,
                                            title: title, progress: progress)
            guard c.gate.matches(region, region.lowercased()) else { continue }
            // Highest priority wins; on ties the earlier rule in the file
            // wins (the first is kept via `previous.priority >= new`).
            if let previous = matched, previous.rule.priority >= c.rule.priority { continue }
            matched = c
        }
        guard let result = matched else {
            // Known agent, nothing matched: fall back to idle without
            // visible evidence rather than claiming unknown.
            return AgentScreenDetection(state: .idle)
        }
        return AgentScreenDetection(
            state: result.rule.state,
            skipStateUpdate: result.rule.skipStateUpdate,
            visibleIdle: result.rule.visibleIdle && result.rule.state == .idle,
            visibleBlocker: result.rule.visibleBlocker && result.rule.state == .blocked,
            visibleWorking: result.rule.visibleWorking && result.rule.state == .working)
    }
}

enum AgentDetect {
    private static var ruleSets: [String: AgentRuleSet] = {
        var sets: [String: AgentRuleSet] = [:]
        for (key, rules) in agentManifestTable {
            if let set = AgentRuleSet(rules: rules) { sets[key] = set }
        }
        return sets
    }()

    /// Manifest presence — drives whether a pane gets live detection at all.
    static func hasRules(for command: String?) -> Bool {
        guard let key = AgentCatalog.manifestKey(for: command) else { return false }
        return ruleSets[key] != nil
    }

    static func detect(command: String?, screen: String, title: String, progress: String)
        -> AgentScreenDetection {
        guard let key = AgentCatalog.manifestKey(for: command),
              let set = ruleSets[key] else {
            return AgentScreenDetection(state: .unknown)
        }
        return set.detect(screen: screen, title: title, progress: progress)
    }

    // MARK: Regions (`region()`)

    static func region(_ spec: String, screen: String, title: String, progress: String) -> String {
        switch spec.trimmingCharacters(in: .whitespaces) {
        case "osc_title": return title
        case "osc_progress": return progress
        case "whole_recent": return screen
        case "after_last_prompt_marker": return afterLastPromptMarker(screen)
        case "before_current_prompt_marker": return beforeCurrentPromptMarker(screen)
        case "whole_recent_without_current_prompt_marker":
            return wholeRecentWithoutCurrentPromptMarker(screen)
        case "current_prompt_block_marker": return currentPromptBlockMarker(screen) ?? ""
        case "after_current_prompt_block_marker":
            return afterCurrentPromptBlockMarker(screen) ?? ""
        case "prompt_box_body": return promptBoxBody(screen) ?? ""
        case "above_prompt_box": return abovePromptBox(screen)
        case "last_non_empty_above_prompt_box":
            return lastNonEmptyLine(abovePromptBox(screen))
        case "after_last_horizontal_rule": return afterLastHorizontalRule(screen)
        default:
            if let n = regionCount(spec, "bottom_lines") { return bottomLines(screen, n) }
            if let n = regionCount(spec, "bottom_non_empty_lines") { return bottomNonEmptyLines(screen, n) }
            if let n = regionCount(spec, "top_non_empty_lines") { return topNonEmptyLines(screen, n) }
            return ""
        }
    }

    private static func regionCount(_ spec: String, _ name: String) -> Int? {
        guard spec.hasPrefix(name), let open = spec.firstIndex(of: "("),
              spec.hasSuffix(")") else { return nil }
        let inner = spec[spec.index(after: open)..<spec.index(before: spec.endIndex)]
        return Int(inner.trimmingCharacters(in: .whitespaces))
    }

    private static func lines(of content: String) -> [Substring] {
        content.split(separator: "\n", omittingEmptySubsequences: false)
    }

    private static func bottomLines(_ content: String, _ count: Int) -> String {
        let all = lines(of: content)
        let start = all.count <= count ? 0 : all.count - count
        return all[start...].joined(separator: "\n")
    }

    private static func bottomNonEmptyLines(_ content: String, _ count: Int) -> String {
        let all = lines(of: content)
        var startIndex: Int?
        var seen = 0
        for (i, line) in all.enumerated().reversed() {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            seen += 1
            startIndex = i
            if seen >= count { break }
        }
        guard let start = startIndex else { return "" }
        return all[start...].joined(separator: "\n")
    }

    private static func topNonEmptyLines(_ content: String, _ count: Int) -> String {
        let all = lines(of: content)
        var seen = 0
        var endIndex = all.count
        for (i, line) in all.enumerated() {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            seen += 1
            if seen >= count { endIndex = i + 1; break }
        }
        guard seen > 0 else { return "" }
        return all[..<endIndex].joined(separator: "\n")
    }

    // Codex prompt markers: "›" prompt lines and •/■/✗/✓ block markers.

    private static func codexPromptLine(_ line: Substring) -> Bool {
        line == "›" || line.hasPrefix("› ")
    }

    private static func codexBlockMarkerLine(_ line: Substring) -> Bool {
        line.hasPrefix("•") || line.hasPrefix("■") || line.hasPrefix("✗") || line.hasPrefix("✓")
    }

    private static func currentCodexPromptIndex(_ all: [Substring]) -> Int? {
        guard let promptIndex = all.lastIndex(where: codexPromptLine) else { return nil }
        if all[(promptIndex + 1)...].contains(where: codexBlockMarkerLine) { return nil }
        return promptIndex
    }

    private static func afterLastPromptMarker(_ content: String) -> String {
        let all = lines(of: content)
        guard let index = all.lastIndex(where: codexPromptLine) else { return content }
        return all[(index + 1)...].joined(separator: "\n")
    }

    private static func beforeCurrentPromptMarker(_ content: String) -> String {
        let all = lines(of: content)
        guard let index = currentCodexPromptIndex(all) else { return content }
        return all[..<index].joined(separator: "\n")
    }

    private static func wholeRecentWithoutCurrentPromptMarker(_ content: String) -> String {
        return currentCodexPromptIndex(lines(of: content)) == nil ? content : ""
    }

    private static func currentPromptBlockMarker(_ content: String) -> String? {
        let all = lines(of: content)
        guard let promptIndex = currentCodexPromptIndex(all) else { return nil }
        return all[..<promptIndex].last(where: codexBlockMarkerLine).map(String.init)
    }

    private static func afterCurrentPromptBlockMarker(_ content: String) -> String? {
        let all = lines(of: content)
        guard let promptIndex = currentCodexPromptIndex(all),
              let blockIndex = all[..<promptIndex].lastIndex(where: codexBlockMarkerLine)
        else { return nil }
        return all[blockIndex...].joined(separator: "\n")
    }

    // Box-drawing regions (Claude's input box, prompt_box_*).

    private static func isHorizontalRule(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let ruleChars = trimmed.prefix { $0 == "─" }.count
        guard ruleChars > 0 else { return false }
        let suffix = trimmed.drop { $0 == "─" }.trimmingCharacters(in: .whitespaces)
        return suffix.isEmpty || ruleChars >= 3
    }

    private static func promptBoxTopBorderIndex(_ all: [Substring]) -> Int? {
        var borderCount = 0
        for index in all.indices.reversed() {
            if isHorizontalRule(all[index]) {
                borderCount += 1
                if borderCount == 2 { return index }
            }
        }
        return nil
    }

    private static func promptBoxBody(_ content: String) -> String? {
        let all = lines(of: content)
        guard let top = promptBoxTopBorderIndex(all) else { return nil }
        let end = all[(top + 1)...].firstIndex(where: isHorizontalRule) ?? all.count
        return all[(top + 1)..<end].joined(separator: "\n")
    }

    private static func abovePromptBox(_ content: String) -> String {
        let all = lines(of: content)
        guard let top = promptBoxTopBorderIndex(all) else { return content }
        return all[..<top].joined(separator: "\n")
    }

    private static func afterLastHorizontalRule(_ content: String) -> String {
        let all = lines(of: content)
        guard let index = all.lastIndex(where: isHorizontalRule) else { return content }
        return all[(index + 1)...].joined(separator: "\n")
    }

    private static func lastNonEmptyLine(_ content: String) -> String {
        let all = lines(of: content)
        return all.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }).map(String.init) ?? ""
    }
}

// MARK: - Publish state machine

/// Debounces raw screen detections into published state transitions.
/// Constants: 300ms tick, 100ms pending-idle recheck, 3
/// confirmations / 700ms hold for working→idle, 800ms stable-blocker
/// refresh, 3s startup grace.
final class AgentStatusTracker {
    static let tickInterval: TimeInterval = 0.3
    private static let pendingIdleConfirmations = 3
    private static let pendingIdleCap: TimeInterval = 0.7
    private static let stableSignalRefresh: TimeInterval = 0.8
    private static let startupGrace: TimeInterval = 3.0

    /// Fired only when the visible state actually changed (or the pane died).
    var onPublish: ((AgentActivity, _ processExited: Bool) -> Void)?

    private(set) var state: AgentActivity = .unknown
    private var visibleIdle = false
    private var visibleBlocker = false
    private var visibleWorking = false
    private var pendingIdleStarted: Date?
    private var pendingIdleConfirmations = 0
    private var lastScanContentSeq: UInt64?
    private var lastVisibleRefresh: Date?
    private var graceUntil: Date?

    /// Restart after (re)attach: unknown until the first evidence, then a
    /// fresh 3s grace like the agent-startup window.
    func restartGrace(now: Date = Date()) {
        state = .unknown
        visibleIdle = false
        visibleBlocker = false
        visibleWorking = false
        pendingIdleStarted = nil
        pendingIdleConfirmations = 0
        lastScanContentSeq = nil
        lastVisibleRefresh = nil
        graceUntil = now.addingTimeInterval(Self.startupGrace)
    }

    /// An idle pane whose content has
    /// not changed since the last scan needs no screen read at all.
    func shouldReadScreen(contentSeq: UInt64) -> Bool {
        guard state == .idle, pendingIdleStarted == nil,
              let last = lastScanContentSeq, last == contentSeq else { return true }
        return false
    }

    /// One detection pass. `screen` is only consulted when the tracker asks
    /// for it (`shouldReadScreen`); pass the cached value you already have.
    func tick(now: Date = Date(),
              command: String?, contentSeq: UInt64,
              screen: () -> String, title: String, progress: String,
              processExited: Bool = false) {
        if let until = graceUntil {
            guard now >= until else {
                pendingIdleStarted = nil
                pendingIdleConfirmations = 0
                return
            }
            graceUntil = nil
            lastScanContentSeq = nil
        }

        let detection: AgentScreenDetection
        if processExited {
            detection = AgentScreenDetection(state: .idle, visibleIdle: true)
        } else {
            detection = AgentDetect.detect(command: command, screen: screen(),
                                           title: title, progress: progress)
            lastScanContentSeq = contentSeq
            guard !detection.skipStateUpdate else {
                pendingIdleStarted = nil
                pendingIdleConfirmations = 0
                return
            }
        }

        let newState = detection.state
        let nextVisibleIdle = detection.visibleIdle && newState == .idle
        let nextVisibleBlocker = detection.visibleBlocker && newState == .blocked
        let nextVisibleWorking = detection.visibleWorking && newState == .working

        // PendingIdleConfirmation: a working pane that momentarily
        // reads idle (mid-redraw) stays working for up to 700ms / 3 passes.
        let workingToPlainIdle = state == .working && newState == .idle
            && !nextVisibleIdle && !nextVisibleBlocker && !processExited
        if workingToPlainIdle {
            if pendingIdleStarted == nil {
                pendingIdleStarted = now
                pendingIdleConfirmations = 0
                return
            }
            if now.timeIntervalSince(pendingIdleStarted!) >= Self.pendingIdleCap {
                pendingIdleStarted = nil
                pendingIdleConfirmations = 0
            } else {
                pendingIdleConfirmations += 1
                if pendingIdleConfirmations < Self.pendingIdleConfirmations { return }
                pendingIdleStarted = nil
                pendingIdleConfirmations = 0
            }
        } else {
            pendingIdleStarted = nil
            pendingIdleConfirmations = 0
        }

        let stableBlocker = nextVisibleBlocker && visibleBlocker
        let refreshDue = stableBlocker
            && (lastVisibleRefresh.map { now.timeIntervalSince($0) >= Self.stableSignalRefresh } ?? true)

        let changed = newState != state || nextVisibleIdle != visibleIdle
            || nextVisibleBlocker != visibleBlocker || nextVisibleWorking != visibleWorking
        if !changed && !processExited && !refreshDue { return }

        state = newState
        visibleIdle = nextVisibleIdle
        visibleBlocker = nextVisibleBlocker
        visibleWorking = nextVisibleWorking
        if stableBlocker { lastVisibleRefresh = now }
        onPublish?(state, processExited)
    }
}

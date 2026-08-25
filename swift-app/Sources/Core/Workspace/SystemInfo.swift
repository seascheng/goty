// goty — see CLAUDE.md for the working principles.
import Foundation

// MARK: - Server system info (the Info tab; machine-fixed, not cwd-derived)

/// What the Info tab shows about the machine a workspace runs ON —
/// local or one ssh host. One sh compound command produces tagged lines;
/// everything else (composition, formatting) happens here.
struct SystemInfo: Equatable {
    var osName = ""
    var kernel = ""
    var cpu = ""
    var gpu = ""
    /// Bytes; formatted at display time.
    var memoryBytes: Int64?
    var ip = ""
    /// Epoch seconds of last boot, when the machine reported it.
    var bootEpoch: Int64?

    /// The one command that answers everything, POSIX sh both sides of
    /// ssh. Each field's fallback chain is the non-Apple path; anything
    /// missing stays empty and renders as "—".
    static let command = [
        "echo \"OSV $(sw_vers -productVersion 2>/dev/null)\"",
        "echo \"OSR $(grep -m1 PRETTY_NAME= /etc/os-release 2>/dev/null | cut -d= -f2)\"",
        "echo \"OSN $(uname -s)\"",
        "echo \"KER $(uname -r)\"",
        "echo \"CPU $(sysctl -n machdep.cpu.brand_string 2>/dev/null || grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2-)\"",
        "echo \"GPU $(system_profiler SPDisplaysDataType 2>/dev/null | grep -m1 'Chipset Model' | cut -d: -f2- || lspci 2>/dev/null | grep -m1 -i 'vga compatible' | cut -d: -f3-)\"",
        "echo \"MEM $(sysctl -n hw.memsize 2>/dev/null || grep MemTotal /proc/meminfo 2>/dev/null | cut -d: -f2 | tr -dc 0-9)\"",
        "echo \"IP $(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || hostname -I 2>/dev/null | cut -d\" \" -f1)\"",
        "echo \"BOOT $(sysctl -n kern.boottime 2>/dev/null || grep btime /proc/stat 2>/dev/null | cut -d\" \" -f2)\"",
    ].joined(separator: "; ")

    /// Parse the tagged lines. `sec = N` inside kern.boottime is the
    /// only nested number worth digging for.
    static func parse(_ stdout: String) -> SystemInfo {
        var info = SystemInfo()
        for line in stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            switch parts[0] {
            case "OSV":
                if !value.isEmpty {
                    info.osName = (info.osName.isEmpty ? "macOS " : info.osName + " ") + value
                }
            case "OSR":
                let clean = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if !clean.isEmpty { info.osName = clean }
            case "OSN":
                if info.osName.isEmpty { info.osName = value }
            case "KER": info.kernel = value
            case "CPU": info.cpu = value
            case "GPU": info.gpu = value
            case "MEM": info.memoryBytes = Int64(value)
            case "IP": info.ip = value
            case "BOOT":
                // `{ sec = 1692720000, usec = 0 } …` or a bare epoch.
                if let open = value.range(of: "sec = ") {
                    let rest = value[open.upperBound...]
                    let digits = rest.prefix { $0.isNumber }
                    info.bootEpoch = Int64(digits)
                } else {
                    info.bootEpoch = Int64(value)
                }
            default: break
            }
        }
        return info
    }

    var memoryText: String {
        guard let memoryBytes, memoryBytes > 0 else { return "—" }
        let gb = Double(memoryBytes) / 1_000_000_000
        return gb >= 10 || gb == gb.rounded()
            ? String(format: "%.0f GB", gb)
            : String(format: "%.1f GB", gb)
    }

    /// "2026-08-20 09:12 · up 2d 4h" — absolute plus elapsed, the two
    /// halves answer different questions.
    var bootText: String {
        guard let bootEpoch, bootEpoch > 0 else { return "—" }
        let boot = Date(timeIntervalSince1970: TimeInterval(bootEpoch))
        let up = Date().timeIntervalSince(boot)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        if up < 3600 { return fmt.string(from: boot) + " · up <1h" }
        let hours = Int(up / 3600)
        let days = hours / 24
        let rem = hours % 24
        let elapsed = days > 0 ? "\(days)d \(rem)h" : "\(rem)h"
        return fmt.string(from: boot) + " · up \(elapsed)"
    }
}

/// Same discipline as the other stores: main-thread state, one serial
/// queue, TTL so focus churn does not become an ssh storm. System facts
/// move on the scale of reboots, not seconds — the TTL is minutes.
final class SystemInfoStore {
    static let shared = SystemInfoStore()

    private let queue = DispatchQueue(label: "goty.sysinfo", qos: .utility)
    private var cache: [String: SystemInfo] = [:]      // host ?? "" → info
    private var fetchedAt: [String: Date] = [:]
    private var inFlight = Set<String>()
    private let ttl: TimeInterval

    init(ttl: TimeInterval = 600) { self.ttl = ttl }

    /// Last known answer (main thread); nil = never fetched / failed.
    func cached(host: String?) -> SystemInfo? {
        cache[host ?? ""]
    }

    func fetch(host: String?, force: Bool = false,
               onChange: ((SystemInfo?) -> Void)? = nil) {
        let key = host ?? ""
        if !force, inFlight.contains(key) { return }
        if !force, let at = fetchedAt[key],
           Date().timeIntervalSince(at) < ttl {
            onChange?(cache[key])
            return
        }
        inFlight.insert(key)
        fetchedAt[key] = Date()
        queue.async { [weak self] in
            let result = ScmTransport.run(SystemInfo.command, host: host)
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.remove(key)
                let info = result.code == 0
                    ? SystemInfo.parse(String(data: result.stdout, encoding: .utf8) ?? "")
                    : nil
                if let info { self.cache[key] = info }
                onChange?(info)
            }
        }
    }
}

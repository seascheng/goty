// goty — see CLAUDE.md for the working principles.
import Foundation

/// Release-mode replay-throughput probe for the shared agent channel
/// (spec: 2026-09-14 concurrency/performance, performance verification).
/// Builds one 16 MiB ndjson replay, feeds it through JSONRPCChannel in
/// one call, and prints routed-count-verified throughput. The numbers
/// feed the before/after lock-separation comparison only — no broader
/// CPU/memory claims.
@main
enum AgentBench {
    static func main() {
        let line = #"{"jsonrpc":"2.0","method":"item/agentMessage/delta","params":{"delta":"benchmark payload"}}"# + "\n"
        let lineBytes = Array(line.utf8)
        let targetBytes = 16 * 1024 * 1024
        let repetitions = targetBytes / lineBytes.count
        var replay = [UInt8]()
        replay.reserveCapacity(repetitions * lineBytes.count)
        for _ in 0 ..< repetitions {
            replay.append(contentsOf: lineBytes)
        }

        let channel = JSONRPCChannel()
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            channel.feed(replay, replay: true)
        }
        let parts = elapsed.components
        let seconds = Double(parts.seconds)
            + Double(parts.attoseconds) / 1_000_000_000_000_000_000
        let mib = Double(replay.count) / 1_048_576
        let throughput = mib / max(seconds, 0.000_001)

        guard channel.messagesRouted == repetitions else {
            fputs("agentbench: routed \(channel.messagesRouted), expected \(repetitions)\n", stderr)
            exit(1)
        }
        print(String(format: "agentbench bytes=%d messages=%d seconds=%.6f mib_per_second=%.2f",
                     replay.count, repetitions, seconds, throughput))
    }
}

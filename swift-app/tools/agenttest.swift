// agenttest.swift — headless contract tests for Core/Agent (ACP).
//
// Built and run by run-tests.sh; NOT part of the app binary.
import Foundation
@testable import goty

@main
enum AgentTest {
    static func main() {
        var failures = 0
        func check(_ cond: Bool, _ name: String) {
            if cond { print("  ok  \(name)") } else { failures += 1; print("FAIL  \(name)") }
        }

        print("— agentSpawnPayload —")
        let grid = SessionGrid(columns: 120, rows: 40, cellWidth: 8, cellHeight: 16)
        let payload = SessionDaemon.agentSpawnPayload(
            cwd: "/tmp", shell: "omp", args: ["acp"],
            environment: ["PATH": "/usr/bin"], grid: grid,
            noEcho: true, ringBytes: 67_108_864)
        check(payload["no_echo"] as? Bool == true, "no_echo=true present")
        check(payload["ring_bytes"] as? UInt64 == 67_108_864, "ring_bytes present")
        check((payload["args"] as? [String]) == ["acp"], "args pass through")
        check((payload["env"] as? [[String]]) == [["PATH", "/usr/bin"]], "env pairs")
        let plain = SessionDaemon.agentSpawnPayload(
            cwd: nil, shell: "/bin/zsh", args: ["-l"], environment: [:],
            grid: grid, noEcho: false, ringBytes: nil)
        check(plain["no_echo"] == nil && plain["ring_bytes"] == nil,
              "terminal panes serialize without the new keys")
        check((plain["size"] as? [String: UInt16])?["cols"] == 120, "grid passes through")

        if failures > 0 { exit(1) }
        print("agenttest: all passed")
    }
}

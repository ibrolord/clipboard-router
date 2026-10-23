// NON-FDA HOST CHECK helper. A tiny ad-hoc-signed app, given a FRESH bundle identifier on every
// harness run, launched through LaunchServices (`open -n -W`) so that THIS app, not the
// developer's terminal or agent shell, is the responsible process for what it spawns.
//
// usage: testhost <result.json> <probe-report.json> <nonce> <command> [args...]
//
// The host runs the command (the probe) with stdout/stderr discarded, then reads the probe's own
// report and writes <result.json> with: host_result (pass|fail), exit_status, reason (exit|signal),
// nonce, bundle_id, host_pid, ppid, responsible pids (private libSystem call, optional), written_at,
// and the parsed probe report. It never embeds clip content (the probe report holds only check
// names and booleans). The exit status is 0 ONLY for a verified pass; the `open -W` status is not
// evidence by itself -- the harness asserts on the artifact.

import Darwin
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 5 else { exit(2) }
let resultPath = arguments[1]
let reportPath = arguments[2]
let nonce = arguments[3]

typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t
func responsibleSymbol() -> UnsafeMutableRawPointer? {
    dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
}
func responsible(_ pid: pid_t) -> Any {
    guard let symbol = responsibleSymbol() else { return NSNull() }
    let function = unsafeBitCast(symbol, to: ResponsibleFunction.self)
    let value = function(pid)
    return value > 0 ? Int(value) : NSNull()
}

func writeResult(_ fields: [String: Any]) {
    var record = fields
    record["nonce"] = nonce
    record["bundle_id"] = Bundle.main.bundleIdentifier ?? NSNull()
    record["host_pid"] = Int(getpid())
    record["ppid"] = Int(getppid())
    record["responsible_pid_of_host"] = responsible(getpid())
    record["responsible_symbol_available"] = responsibleSymbol() != nil
    record["written_at"] = Date().timeIntervalSince1970
    guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .prettyPrinted]) else { exit(4) }
    try? data.write(to: URL(fileURLWithPath: resultPath), options: .atomic)
}

let process = Process()
process.executableURL = URL(fileURLWithPath: arguments[4])
process.arguments = Array(arguments.dropFirst(5))
process.standardOutput = FileHandle.nullDevice
process.standardError = FileHandle.nullDevice
process.standardInput = FileHandle.nullDevice
do {
    try process.run()
} catch {
    writeResult(["host_result": "spawn_failed", "exit_status": -1, "reason": "spawn_failed"])
    exit(3)
}
let childResponsible = responsible(process.processIdentifier)
process.waitUntilExit()

var probe: [String: Any]?
if let data = try? Data(contentsOf: URL(fileURLWithPath: reportPath)),
   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    probe = parsed
}
func checkPassed(_ report: [String: Any]?, _ name: String) -> Bool {
    guard let checks = report?["checks"] as? [[String: Any]] else { return false }
    return checks.contains { ($0["name"] as? String) == name && ($0["ok"] as? Bool) == true }
}
let exitStatus = Int(process.terminationStatus)
let reason = process.terminationReason == .exit ? "exit" : "signal"
let probePassed = (probe?["passed"] as? Bool) == true
let canaryMatch = checkPassed(probe, "get_shared_clip_exact_canary") && checkPassed(probe, "vault_exact_synthetic_text")
let verified = exitStatus == 0 && reason == "exit" && probePassed && canaryMatch
var fields: [String: Any] = [
    "host_result": verified ? "pass" : "fail",
    "exit_status": exitStatus,
    "reason": reason,
    "probe_passed": probePassed,
    "exact_synthetic_content_match": canaryMatch,
    "responsible_pid_of_child": childResponsible,
]
fields["probe"] = probe ?? NSNull()
writeResult(fields)
exit(verified ? 0 : 1)

#!/usr/bin/env python3
"""Per-phase timing summary of one cold run (run with `python3 -I`).

usage: summarize_cold.py <fixture.log> <probe-report.json> <cr-stderr.log>
Reads only reason codes, timestamps and timings (the logs are content-free by construction).
"""
import datetime
import json
import re
import sys


def parse_wall(text):
    return datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))


def main():
    fixture_log, report_path, stderr_log = sys.argv[1:4]
    walls = {}
    events = []
    for raw in open(fixture_log):
        stamp, _, rest = raw.rstrip("\n").partition(" ")
        try:
            when = parse_wall(stamp)
        except ValueError:
            continue
        match = re.match(r"t_ms=(\d+) event=(\S+)(?: reason=(\S+))?", rest)
        if match:
            events.append((int(match.group(1)), match.group(2), match.group(3) or "", when))
        else:
            walls.setdefault(rest.split(" ")[0].split("=")[0], when)
    report = json.load(open(report_path))
    out = []

    def delta(a, b):
        return int((walls[b] - walls[a]).total_seconds() * 1000) if a in walls and b in walls else None

    out.append(f"fixture_start -> fixture_identity_ok_ms: {delta('fixture_start', 'fixture_identity_ok')}")
    out.append(f"fixture_start -> fixture_listening_ms: {delta('fixture_start', 'fixture_listening')}")
    first = [e for e in events if e[1] == "peer_verified"]
    out.append(f"first connection peer_verified t_ms: {first[0][0] if first else None} (handshake timeout 15000 ms now, 2000 ms before)")
    for t_ms, name, reason, _ in events:
        if name in ("peer_verified", "session_opened", "reject", "close", "pairing_decided", "handoff", "connection_closed"):
            out.append(f"  fixture event t_ms={t_ms} {name} {reason}".rstrip())
    timings = report.get("timings", {})
    out.append(f"probe initialize_ms: {timings.get('initialize_ms')}")
    out.append(f"probe tools_list_ms: {timings.get('tools_list_ms')}")
    out.append(f"probe first_tool_call_ms (connect+verify+hello+pairing+request): {timings.get('first_tool_call_ms')}")
    out.append(f"probe passed: {report.get('passed')}  cr_exit: {report.get('cr_exit_status')}")
    out.append("cr stderr lines (timestamped, content-free):")
    out.extend("  " + line.rstrip("\n") for line in open(stderr_log))
    handshake_limit = 2000
    if first:
        out.append(f"peer_verified t_ms {first[0][0]} exceeds old 2000 ms handshake budget: {first[0][0] > handshake_limit}")
    unexpected = [l for l in out if "closed unexpectedly" in l]
    out.append(f"'server closed unexpectedly' observed: {bool(unexpected)}")
    print("\n".join(out))
    return 0


sys.exit(main())

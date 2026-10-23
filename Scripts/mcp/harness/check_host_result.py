#!/usr/bin/env python3
"""Asserts the TestHost result artifact (run with `python3 -I`).

usage: check_host_result.py <result.json> <nonce> <launch-epoch> <expected-bundle-id>

Exit 0 + "PASS ..."        everything verified, including the launch/responsibility conditions
Exit 3 + "INCOMPLETE ..."  the probe round trip passed but the no-FDA / responsible-process
                           conditions could not be established (reported distinctly, not as PASS)
Exit 1 + "FAIL ..."        missing/stale/wrong artifact or a failed round trip
"""
import json
import os
import sys


def main():
    path, nonce, launch, bundle = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]
    try:
        stat = os.stat(path)
        data = json.load(open(path))
    except (OSError, ValueError) as problem:
        print("FAIL no readable result artifact: %s" % type(problem).__name__)
        return 1
    if stat.st_mtime < launch - 1:
        print("FAIL artifact older than the launch (mtime)")
        return 1
    if data.get("nonce") != nonce or not isinstance(data.get("written_at"), (int, float)) or data["written_at"] < launch:
        print("FAIL artifact nonce/written_at do not belong to this launch")
        return 1
    hard = []
    if data.get("host_result") != "pass":
        hard.append("host_result=%s" % data.get("host_result"))
    if data.get("exit_status") != 0:
        hard.append("exit_status=%s" % data.get("exit_status"))
    if data.get("reason") != "exit":
        hard.append("reason=%s" % data.get("reason"))
    probe = data.get("probe")
    if not isinstance(probe, dict) or probe.get("passed") is not True:
        hard.append("probe.passed != true")
    if data.get("exact_synthetic_content_match") is not True:
        hard.append("exact synthetic content not matched")
    if data.get("bundle_id") != bundle:
        hard.append("bundle_id mismatch")
    if hard:
        print("FAIL " + "; ".join(hard))
        return 1
    soft = []
    if data.get("ppid") != 1:
        soft.append("host ppid=%s (not launchd)" % data.get("ppid"))
    if not data.get("responsible_symbol_available"):
        soft.append("responsibility API unavailable")
    else:
        if data.get("responsible_pid_of_host") != data.get("host_pid"):
            soft.append("host is not its own responsible process")
        if data.get("responsible_pid_of_child") != data.get("host_pid"):
            soft.append("probe's responsible process is not the host")
    if soft:
        print("INCOMPLETE round trip passed but: " + "; ".join(soft))
        return 3
    print("PASS fresh_id=%s host_pid=%s ppid=1 responsible=host exact_content=true" % (bundle, data.get("host_pid")))
    return 0


sys.exit(main())

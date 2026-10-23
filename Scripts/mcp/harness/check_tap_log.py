#!/usr/bin/env python3
"""Asserts a stdio_tap.py metadata log shows a complete MCP tool round trip (run with `python3 -I`).

usage: check_tap_log.py <tap-log>
Requires: initialize, tools/list, tools/call list_shared_clips and tools/call get_shared_clip
each answered by a response with is_error false and no rpc_error. Reads metadata only.
"""
import json
import sys


def main():
    entries = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
    sent = [e for e in entries if e.get("dir") == "client->server"]
    got = [e for e in entries if e.get("dir") == "server->client"]
    problems = []
    methods = [e.get("method") for e in sent]
    for needed in ("initialize", "tools/list"):
        if needed not in methods:
            problems.append("missing " + needed)
    answered = {e.get("method") for e in got if e.get("id") is not None and not e.get("rpc_error")}
    for needed in ("initialize", "tools/list"):
        if needed not in answered:
            problems.append("no response to " + needed)
    for tool in ("list_shared_clips", "get_shared_clip"):
        if not any(e.get("tool") == tool for e in sent):
            problems.append("no tools/call " + tool)
        replies = [e for e in got if e.get("tool") == tool]
        if not replies:
            problems.append("no response for " + tool)
        elif not all(e.get("is_error") is False and not e.get("rpc_error") for e in replies):
            problems.append("isError not false for " + tool)
    for problem in problems:
        print("FAIL " + problem)
    print("tap-log " + ("FAIL" if problems else "PASS"))
    return 1 if problems else 0


sys.exit(main())

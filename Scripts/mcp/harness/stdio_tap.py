#!/usr/bin/env python3
"""Metadata-only, byte-transparent stdio tap for MCP (newline-delimited JSON-RPC).

usage:  python3 -I stdio_tap.py [--child-stderr FILE] <log-path> <command> [args...]
        python3 -I stdio_tap.py --self-test

Forwards client stdin to the child's stdin, the child's stdout to our stdout, and lets the
child inherit our stderr unchanged (or, with --child-stderr, appends the child's stderr to
FILE so a harness can scan it for leaks). Bytes are forwarded verbatim (os.read/os.write
on raw descriptors); a separate copy is split on newlines for the log.

For every JSON-RPC message the log gets ONE JSON line holding only: wall timestamp,
direction, method, id, tool name (for tools/call and the response to it), whether the result
isError, whether it was an RPC error, and the byte length. It NEVER logs params, arguments,
result content or text. EOF on our stdin closes the child's stdin; the child's exit status
is propagated (128+signal for signals).
"""
import datetime
import json
import os
import subprocess
import sys
import tempfile
import threading

C2S = "client->server"
S2C = "server->client"


class Meta:
    def __init__(self, log):
        self.log = log
        self.lock = threading.Lock()
        self.tool_by_id = {}
        self.method_by_id = {}

    def write(self, entry):
        entry["ts"] = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds")
        with self.lock:
            self.log.write(json.dumps(entry, sort_keys=True) + "\n")
            self.log.flush()

    def one(self, direction, line):
        entry = {"dir": direction, "bytes": len(line) + 1}
        try:
            message = json.loads(line)
        except ValueError:
            entry["kind"] = "non_json"
            self.write(entry)
            return
        for item in (message if isinstance(message, list) else [message]):
            record = dict(entry)
            if not isinstance(item, dict):
                record["kind"] = "non_object"
                self.write(record)
                continue
            message_id = item.get("id")
            method = item.get("method")
            if isinstance(method, str):
                record["method"] = method
                if message_id is not None:
                    record["id"] = message_id if isinstance(message_id, (int, str)) else None
                    self.method_by_id[(direction, message_id)] = method
                params = item.get("params")
                if method == "tools/call" and isinstance(params, dict) and isinstance(params.get("name"), str):
                    record["tool"] = params["name"]
                    if message_id is not None:
                        self.tool_by_id[message_id] = params["name"]
            else:
                other = S2C if direction == C2S else C2S
                record["id"] = message_id if isinstance(message_id, (int, str)) else None
                record["method"] = self.method_by_id.get((other, message_id))
                if message_id in self.tool_by_id:
                    record["tool"] = self.tool_by_id[message_id]
                if "error" in item:
                    record["rpc_error"] = True
                result = item.get("result")
                if isinstance(result, dict) and "isError" in result:
                    record["is_error"] = result.get("isError") is True
                elif isinstance(result, dict):
                    record["is_error"] = False
            self.write(record)

    def feed(self, direction, state, chunk):
        state["buf"] += chunk
        while True:
            index = state["buf"].find(b"\n")
            if index < 0:
                break
            line, state["buf"] = state["buf"][:index], state["buf"][index + 1:]
            if line.strip():
                self.one(direction, line)

    def flush_tail(self, direction, state):
        if state["buf"].strip():
            self.one(direction, state["buf"])
        state["buf"] = b""


def write_all(fd, data):
    view = memoryview(data)
    while view:
        written = os.write(fd, view)
        view = view[written:]


def run(log_path, command, child_stderr=None):
    meta_log = open(log_path, "a")
    meta = Meta(meta_log)
    err_handle = open(child_stderr, "ab") if child_stderr else None
    child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err_handle, bufsize=0)

    def pump_in():
        state = {"buf": b""}
        try:
            while True:
                chunk = os.read(0, 65536)
                if not chunk:
                    break
                meta.feed(C2S, state, chunk)
                write_all(child.stdin.fileno(), chunk)
        except OSError:
            pass
        finally:
            meta.flush_tail(C2S, state)
            try:
                child.stdin.close()
            except OSError:
                pass

    threading.Thread(target=pump_in, daemon=True).start()
    state = {"buf": b""}
    try:
        while True:
            chunk = os.read(child.stdout.fileno(), 65536)
            if not chunk:
                break
            meta.feed(S2C, state, chunk)
            write_all(1, chunk)
    except OSError:
        pass
    meta.flush_tail(S2C, state)
    code = child.wait()
    meta.write({"dir": "process", "exit_status": code})
    meta_log.close()
    return 128 - code if code < 0 else code


CHILD_FOR_SELF_TEST = r'''
import sys, json
sys.stderr.write("child-stderr-line\n"); sys.stderr.flush()
for raw in sys.stdin.buffer:
    msg = json.loads(raw)
    if "id" in msg:
        if msg["method"] == "tools/call":
            out = {"jsonrpc": "2.0", "id": msg["id"], "result": {"content": [{"type": "text", "text": "SECRET-RESULT-TEXT"}], "isError": msg["params"]["arguments"].get("fail", False)}}
        else:
            out = {"jsonrpc": "2.0", "id": msg["id"], "result": {"ok": True}}
        sys.stdout.write(json.dumps(out) + "\n"); sys.stdout.flush()
sys.exit(7)
'''


def self_test():
    messages = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"clientInfo": {"name": "SECRET-CLIENT"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "get_shared_clip", "arguments": {"id": "SECRET-ARG"}}},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "list_shared_clips", "arguments": {"fail": True}}},
    ]
    payload = b"".join((json.dumps(m, separators=(",", ":")) + "\n").encode() for m in messages)
    with tempfile.TemporaryDirectory() as directory:
        log_path = os.path.join(directory, "tap.log")
        out_path = os.path.join(directory, "out.bin")
        err_path = os.path.join(directory, "err.txt")
        in_path = os.path.join(directory, "in.bin")
        with open(in_path, "wb") as handle:
            handle.write(payload)
        with open(in_path, "rb") as stdin, open(out_path, "wb") as stdout, open(err_path, "wb") as stderr:
            status = subprocess.run(
                [sys.executable, "-I", os.path.abspath(__file__), log_path, sys.executable, "-I", "-c", CHILD_FOR_SELF_TEST],
                stdin=stdin, stdout=stdout, stderr=stderr,
            ).returncode
        log = open(log_path).read()
        entries = [json.loads(l) for l in log.splitlines()]
        out = open(out_path, "rb").read()
        failures = []

        def expect(name, ok):
            print(("PASS " if ok else "FAIL ") + name)
            if not ok:
                failures.append(name)

        expect("exit_status_propagated", status == 7)
        expect("child_stderr_passthrough_unchanged", open(err_path, "rb").read() == b"child-stderr-line\n")
        expect("log_has_no_secret_params_or_results", not any(s in log for s in ["SECRET-CLIENT", "SECRET-ARG", "SECRET-RESULT-TEXT", "arguments", "params"]))
        expect("stdout_bytes_are_unaltered", out.count(b"SECRET-RESULT-TEXT") == 2 and out.endswith(b"\n"))
        sent = [e for e in entries if e.get("dir") == C2S]
        got = [e for e in entries if e.get("dir") == S2C]
        expect("client_messages_logged_with_methods", [e.get("method") for e in sent] == ["initialize", "notifications/initialized", "tools/call", "tools/call"])
        expect("tool_names_logged", [e.get("tool") for e in sent if e.get("tool")] == ["get_shared_clip", "list_shared_clips"])
        expect("response_is_error_flags", [e.get("is_error") for e in got if e.get("tool")] == [False, True])
        expect("response_tool_correlated", [e.get("tool") for e in got if e.get("tool")] == ["get_shared_clip", "list_shared_clips"])
        expect("byte_lengths_match", sum(e["bytes"] for e in sent) == len(payload) and sum(e["bytes"] for e in got) == len(out))
        expect("process_exit_logged", entries[-1] == {**entries[-1], "dir": "process", "exit_status": 7})
        allowed = {"ts", "dir", "bytes", "method", "id", "tool", "is_error", "rpc_error", "kind", "exit_status"}
        expect("only_metadata_keys", all(set(e) <= allowed for e in entries))
    print("self-test " + ("FAIL" if failures else "PASS"))
    return 1 if failures else 0


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        sys.exit(self_test())
    argv = sys.argv[1:]
    child_stderr_path = None
    if len(argv) >= 2 and argv[0] == "--child-stderr":
        child_stderr_path, argv = argv[1], argv[2:]
    if len(argv) < 2:
        sys.stderr.write("usage: stdio_tap.py [--child-stderr FILE] <log-path> <command> [args...]\n")
        sys.exit(2)
    sys.exit(run(argv[0], argv[1:], child_stderr_path))

#!/usr/bin/env python3
"""Scripted MCP stdio client that drives the REAL `cr mcp` and strictly asserts the result.

Run with `python3 -I mcp_probe.py ...`. All data is synthetic (constants below must match
Scripts/mcp/harness/Fixture/main.swift). The report it writes never contains tool content,
only check names, booleans, tool names, timings and cr's stderr reason codes.

Exit status: 0 only if every check passed; 1 if any check failed or cr misbehaved;
2 on usage errors. A bridge failure can never exit 0.

Profiles
  approve          pairing approved, vault approved (full positive path)
  deny_pairing     pairing denied: no tool call may yield content
  vault_deny       pairing approved, vault denied
  refuse_connect   cr starts but must refuse the server (needs --expect-reason)
  exit_unavailable cr must exit 69 with `cr mcp: unavailable (<reason>)` (needs --expect-reason)
  initialize_codex_shape  initialize with the capability shapes Codex sends (experimental,
                   elicitation form/url, clientInfo.title) then tools/list: must succeed
"""
import argparse
import datetime
import json
import queue
import re
import subprocess
import sys
import threading
import time

CANARY = "CR-SYNTHETIC-CANARY-7f3a"
SECOND = "CR-SYNTHETIC-SECOND-4e8d"
EXCLUDED = "CR-SYNTHETIC-EXCLUDED-b05c"
VAULT = "CR-SYNTHETIC-VAULT-91c2"
TITLES = {
    "5A1C0DE0-0000-4000-8000-00000000000A": "CR-SYNTHETIC-TITLE-ALPHA",
    "5A1C0DE0-0000-4000-8000-00000000000B": "CR-SYNTHETIC-TITLE-BRAVO",
}
ID_A = "5A1C0DE0-0000-4000-8000-00000000000A"
ID_B = "5A1C0DE0-0000-4000-8000-00000000000B"
ID_EXCLUDED = "5A1C0DE0-0000-4000-8000-00000000000C"
ID_RANDOM = "0F0F0F0F-1234-4321-8765-0123456789AB"
EXCLUDED_TITLE = "CR-SYNTHETIC-TITLE-EXCLUDED"
PURPOSE = "CR-PROBE-PURPOSE-5c8e"
CLIENT_NAME = "cr-harness-probe-NAMEX9"
EXPECTED_TOOLS = ["get_shared_clip", "list_shared_clips", "request_vault_item", "sync_status"]
NOT_FOUND_TEXT = "No shared clip with that id is available."
VAULT_DENIED_TEXT = "The user declined the Vault request."

# Strings that must never appear in cr's stderr or the fixture log.
FORBIDDEN = [CANARY, SECOND, EXCLUDED, VAULT, PURPOSE, CLIENT_NAME, EXCLUDED_TITLE] + list(TITLES.values())
# Strings that must never appear in any tool result when access was not granted.
CONTENT = [CANARY, SECOND, EXCLUDED, VAULT] + list(TITLES.values()) + [EXCLUDED_TITLE]


class Abort(Exception):
    pass


def wall():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds")


class Probe:
    def __init__(self, cr, timeout):
        self.cr = cr
        self.timeout = timeout
        self.checks = []
        self.timings = {}
        self.stderr_lines = []  # (t_ms, wall, text)
        self.stdout_bytes = 0
        self.stdout_raw = []
        self.out_queue = queue.Queue()
        self.next_id = 1
        self.t0 = time.monotonic()
        self.spawn_wall = wall()
        self.proc = subprocess.Popen(
            cr + ["mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            bufsize=0, env={"PATH": "/usr/bin:/bin", "HOME": __import__("os").path.expanduser("~")},
        )
        threading.Thread(target=self._read_stdout, daemon=True).start()
        self.err_thread = threading.Thread(target=self._read_stderr, daemon=True)
        self.err_thread.start()

    def ms(self):
        return int((time.monotonic() - self.t0) * 1000)

    def _read_stdout(self):
        buf = b""
        while True:
            chunk = self.proc.stdout.read(65536)
            if not chunk:
                break
            self.stdout_bytes += len(chunk)
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                self.stdout_raw.append(line)
                self.out_queue.put((self.ms(), line))
        self.out_queue.put((self.ms(), None))

    def _read_stderr(self):
        for raw in iter(self.proc.stderr.readline, b""):
            self.stderr_lines.append((self.ms(), wall(), raw.decode("utf-8", "replace").rstrip("\n")))

    def check(self, name, ok, detail=""):
        self.checks.append({"name": name, "ok": bool(ok), "detail": detail if not ok else ""})
        return bool(ok)

    def send(self, message):
        data = (json.dumps(message, separators=(",", ":")) + "\n").encode()
        try:
            self.proc.stdin.write(data)
        except (BrokenPipeError, OSError):
            raise Abort("stdin closed by cr")

    def notify(self, method, params=None):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        self.send(message)

    def rpc(self, method, params):
        request_id = self.next_id
        self.next_id += 1
        started = time.monotonic()
        self.send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        deadline = started + self.timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise Abort(f"timeout waiting for response to {method}")
            try:
                _, line = self.out_queue.get(timeout=remaining)
            except queue.Empty:
                raise Abort(f"timeout waiting for response to {method}")
            if line is None:
                raise Abort(f"cr closed stdout before answering {method}")
            try:
                message = json.loads(line)
            except ValueError:
                raise Abort("cr wrote a non-JSON line on stdout")
            if isinstance(message, dict) and message.get("id") == request_id and ("result" in message or "error" in message):
                return message, int((time.monotonic() - started) * 1000)

    def call(self, name, arguments):
        message, elapsed = self.rpc("tools/call", {"name": name, "arguments": arguments})
        self.timings.setdefault("tool_calls_ms", []).append({"tool": name, "ms": elapsed})
        result = message.get("result")
        if not isinstance(result, dict):
            return {"isError": True, "texts": [], "rpc_error": True, "canon": json.dumps(message, sort_keys=True)}
        texts = [c.get("text", "") for c in result.get("content", []) if isinstance(c, dict) and c.get("type") == "text"]
        return {
            "isError": result.get("isError") is True,
            "texts": texts,
            "rpc_error": False,
            "canon": json.dumps(result, sort_keys=True),
        }

    def finish(self):
        """Close stdin and require a clean exit."""
        try:
            self.proc.stdin.close()
        except OSError:
            pass
        try:
            code = self.proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
            self.check("cr_exits_after_stdin_eof", False, "cr did not exit within 15s")
            return None
        self.err_thread.join(timeout=2)
        return code

    def stderr_text(self):
        return "\n".join(line for _, _, line in self.stderr_lines)


def blob(*results):
    return "\n".join(r["canon"] for r in results)


CODEX_CAPABILITIES = {"experimental": {"codex/auth-change": {}}, "elicitation": {"form": {}, "url": {}}}


def handshake(p, capabilities=None, client_info=None):
    started = time.monotonic()
    init, elapsed = p.rpc("initialize", {
        "protocolVersion": "2025-06-18",
        "capabilities": capabilities if capabilities is not None else {},
        "clientInfo": client_info or {"name": CLIENT_NAME, "version": "0.0.1"},
    })
    p.timings["initialize_ms"] = elapsed
    ok = "error" not in init and isinstance(init.get("result"), dict) \
        and isinstance(init["result"].get("serverInfo"), dict) and "protocolVersion" in init["result"]
    p.check("initialize_succeeded", ok, "initialize failed")
    if not ok:
        raise Abort("initialize failed")
    p.notify("notifications/initialized")
    listing, elapsed = p.rpc("tools/list", {})
    p.timings["tools_list_ms"] = elapsed
    names = sorted(t.get("name") for t in listing.get("result", {}).get("tools", []))
    p.check("tools_list_exactly_four_expected_names", names == EXPECTED_TOOLS, f"got {names}")


def profile_approve(p, vault_mode):
    handshake(p)
    listed = p.call("list_shared_clips", {})
    p.timings["first_tool_call_ms"] = p.timings["tool_calls_ms"][0]["ms"]
    rows = None
    if not listed["isError"] and listed["texts"]:
        try:
            rows = json.loads(listed["texts"][0])
        except ValueError:
            rows = None
    p.check("list_not_error", not listed["isError"], "list_shared_clips returned isError")
    if isinstance(rows, list):
        got = {r.get("id"): r.get("title") for r in rows}
        p.check("list_exact_ids_and_titles", len(rows) == 2 and got == TITLES, "ids/titles differ from expected")
        sizes = {r.get("id"): r.get("byteCount") for r in rows}
        p.check("list_byte_counts", sizes == {ID_A: len(CANARY), ID_B: len(SECOND)}, "byteCount differs")
        p.check("list_excludes_unshared_clip", ID_EXCLUDED not in got, "excluded id listed")
    else:
        p.check("list_exact_ids_and_titles", False, "list result not a JSON array")

    got_a = p.call("get_shared_clip", {"id": ID_A})
    p.check("get_shared_clip_exact_canary", not got_a["isError"] and got_a["texts"][:1] == [CANARY], "canary text differs")
    got_b = p.call("get_shared_clip", {"id": ID_B})
    p.check("get_shared_clip_second_exact", not got_b["isError"] and got_b["texts"][:1] == [SECOND], "second text differs")
    excluded = p.call("get_shared_clip", {"id": ID_EXCLUDED})
    random = p.call("get_shared_clip", {"id": ID_RANDOM})
    p.check("excluded_id_is_error", excluded["isError"], "excluded id did not error")
    p.check("excluded_and_random_results_identical", excluded["canon"] == random["canon"], "results differ")
    p.check("not_found_text_exact", excluded["texts"][:1] == [NOT_FOUND_TEXT], "not-found text differs")
    p.check("excluded_result_has_no_content", not any(s in blob(excluded, random) for s in CONTENT), "content in not-found")

    status = p.call("sync_status", {})
    status_ok = False
    if not status["isError"] and status["texts"]:
        try:
            status_ok = json.loads(status["texts"][0]).get("snapshotReady") is True
        except ValueError:
            status_ok = False
    p.check("sync_status_ok", status_ok, "sync_status failed")

    vault = p.call("request_vault_item", {"purpose": PURPOSE})
    if vault_mode == "approve":
        p.check("vault_exact_synthetic_text", not vault["isError"] and vault["texts"][:1] == [VAULT], "vault text differs")
    else:
        p.check("vault_denied_is_error", vault["isError"], "vault deny did not error")
        p.check("vault_denied_text_exact", vault["texts"][:1] == [VAULT_DENIED_TEXT], "denied text differs")
        p.check("vault_denied_no_content", VAULT not in vault["canon"], "vault text in denied result")


def profile_denied(p):
    handshake(p)
    results = [
        p.call("list_shared_clips", {}),
        p.call("get_shared_clip", {"id": ID_A}),
        p.call("request_vault_item", {"purpose": PURPOSE}),
        p.call("sync_status", {}),
    ]
    p.check("denied_every_tool_call_is_error", all(r["isError"] for r in results), "a call succeeded without pairing")
    p.check("denied_no_content_in_any_result", not any(s in blob(*results) for s in CONTENT), "content leaked")
    p.check("denied_no_content_on_wire", not any(s.encode() in b"\n".join(p.stdout_raw) for s in CONTENT), "content on stdout")


def profile_refuse(p, reason):
    handshake(p)
    results = [p.call("list_shared_clips", {})]
    p.check("refused_every_tool_call_is_error", all(r["isError"] for r in results), "a call succeeded")
    p.check("refused_no_content", not any(s in blob(*results) for s in CONTENT), "content leaked")
    pattern = re.compile(r"cr mcp: connection failed \(" + re.escape(reason) + r"[a-z0-9_]*\)")
    p.check("cr_stderr_names_refusal_reason", any(pattern.search(l) for _, _, l in p.stderr_lines), f"no '{reason}' in stderr")


def profile_exit(p, reason):
    try:
        code = p.proc.wait(timeout=30)
    except subprocess.TimeoutExpired:
        p.proc.kill()
        p.check("cr_exited", False, "cr did not exit")
        return None
    p.err_thread.join(timeout=2)
    p.check("exit_code_69", code == 69, f"exit code {code}")
    p.check("no_mcp_output_on_stdout", p.stdout_bytes == 0, f"{p.stdout_bytes} bytes on stdout")
    pattern = re.compile(r"^cr mcp: unavailable \(" + re.escape(reason) + r"[a-z0-9_]*\)$")
    p.check("stderr_names_exact_reason", any(pattern.match(l) for _, _, l in p.stderr_lines), f"no '{reason}' line")
    return code


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cr", help="path to cr (run as `cr mcp`)")
    parser.add_argument("--profile", choices=["approve", "deny_pairing", "vault_deny", "refuse_connect", "exit_unavailable", "initialize_codex_shape", "initialize_experimental_only"])
    parser.add_argument("--expect-reason")
    parser.add_argument("--report")
    parser.add_argument("--stderr-log")
    parser.add_argument("--timeout", type=float, default=90.0)
    parser.add_argument("--print-forbidden", action="store_true")
    args = parser.parse_args()
    if args.print_forbidden:
        print("\n".join(FORBIDDEN))
        return 0
    if not args.cr or not args.profile:
        parser.error("--cr and --profile are required")
    if args.profile in ("refuse_connect", "exit_unavailable") and not args.expect_reason:
        parser.error("--expect-reason is required for this profile")

    p = Probe([args.cr], args.timeout)
    code = None
    try:
        if args.profile == "approve":
            profile_approve(p, "approve")
        elif args.profile == "vault_deny":
            profile_approve(p, "deny")
        elif args.profile == "deny_pairing":
            profile_denied(p)
        elif args.profile == "initialize_codex_shape":
            handshake(p, CODEX_CAPABILITIES, {"name": CLIENT_NAME, "title": "Harness", "version": "0.0.1"})
        elif args.profile == "initialize_experimental_only":
            handshake(p, {"experimental": {"codex/auth-change": {}}})
        elif args.profile == "refuse_connect":
            profile_refuse(p, args.expect_reason)
        else:
            code = profile_exit(p, args.expect_reason)
    except Abort as problem:
        p.check("probe_completed", False, str(problem))
    if args.profile != "exit_unavailable":
        code = p.finish()
        p.check("cr_exit_status_zero_after_eof", code == 0, f"exit status {code}")
    leaked = [i for i, s in enumerate(FORBIDDEN) if s in p.stderr_text()]
    p.check("cr_stderr_has_no_content_title_purpose_or_client_name", not leaked, f"{len(leaked)} forbidden strings in stderr")

    reasons = sorted({m for _, _, l in p.stderr_lines for m in re.findall(r"\(([a-z0-9_]+)\)", l)})
    passed = all(c["ok"] for c in p.checks)
    report = {
        "profile": args.profile,
        "passed": passed,
        "spawn_wall": p.spawn_wall,
        "cr_exit_status": code,
        "checks": p.checks,
        "timings": p.timings,
        "stderr_reason_codes": reasons,
        "stderr_line_count": len(p.stderr_lines),
    }
    if args.report:
        with open(args.report, "w") as handle:
            json.dump(report, handle, indent=2, sort_keys=True)
            handle.write("\n")
    if args.stderr_log:
        with open(args.stderr_log, "w") as handle:
            for t_ms, stamp, line in p.stderr_lines:
                handle.write(f"{stamp} t_ms={t_ms} {line}\n")
    for check in p.checks:
        print(("PASS " if check["ok"] else "FAIL ") + check["name"] + ("" if check["ok"] else f"  ({check['detail']})"))
    print(f"probe profile={args.profile} {'PASS' if passed else 'FAIL'} cr_exit={code}")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())

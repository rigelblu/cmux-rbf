#!/usr/bin/env python3
"""cm-124.5: `cmux config doctor` validates `agentEvents` rows and lists the notification types cmux saw with no row.

Runs the built CLI against a throwaway HOME and a mock cmux socket that answers `agent_events.unmapped_types`, the
way the app does. Set CMUX_CLI_BIN to the CLI under test.
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import tempfile
import threading
import time
import uuid
from pathlib import Path
from typing import Any

from test_cli_config_doctor import resolve_cmux_cli

ROW = '{ "agent": "claude", "notification": "agent_needs_input", "means": "question" }'
TYPES = [
    {"agent": "claude", "type": "agent_needs_input", "count": 2, "last_seen_ms": 1795201320000},
    {"agent": "kimi", "type": "plugin_notification", "count": 1, "last_seen_ms": 1795097700000},
    {"agent": "grok", "type": "cm124_grok_type", "count": 1, "last_seen_ms": 1795056000000},
]
NO_ROW = "Notification types with no row"


class MockApp:
    """A unix socket that answers one v2 method, or accepts and never answers."""

    def __init__(self, types: list[dict[str, Any]] | None, silent: bool = False) -> None:
        self.path = f"/tmp/cmux-doctor-{uuid.uuid4().hex[:8]}.sock"
        self.types = types
        self.silent = silent
        self.methods: list[str] = []
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(self.path)
        self.server.listen(4)
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self) -> None:
        while True:
            try:
                connection, _ = self.server.accept()
            except OSError:
                return
            threading.Thread(target=self.handle, args=(connection,), daemon=True).start()

    def handle(self, connection: socket.socket) -> None:
        with connection:
            buffer = b""
            while b"\n" not in buffer:
                chunk = connection.recv(4096)
                if not chunk:
                    return
                buffer += chunk
            request = json.loads(buffer.split(b"\n")[0])
            self.methods.append(request.get("method", ""))
            if self.silent:
                time.sleep(6)
                return
            if request.get("method") == "agent_events.unmapped_types" and self.types is not None:
                body = {"id": request["id"], "ok": True, "result": {"types": self.types}}
            else:
                body = {"id": request["id"], "ok": False, "error": {"code": "unrecognized_method", "message": "no"}}
            connection.sendall((json.dumps(body) + "\n").encode())

    def close(self) -> None:
        self.server.close()
        try:
            os.unlink(self.path)
        except OSError:
            pass


# A profile that refuses every connection to a unix socket under /tmp or /var, so no cmux app on this Mac, Tom's included,
# is "live" for the CLI's implicit socket discovery: the only way to run the no-live-socket path on a machine that has one.
NO_LIVE_SOCKET_PROFILE = '(version 1) (allow default) (deny network-outbound (remote unix-socket (path-regex #"^/(private/)?(tmp|var)/")))'


def run_cli(cli: str, args: list[str], home: Path, socket_path: str | None, cwd: Path | None = None,
            no_live_socket: bool = False) -> subprocess.CompletedProcess[str]:
    env = dict(os.environ)
    env.update({"HOME": str(home), "CMUX_CLI_SENTRY_DISABLED": "1"})
    if socket_path is None:
        env.pop("CMUX_SOCKET_PATH", None)  # the user's own shell: no pinned socket, the implicit default
    else:
        env["CMUX_SOCKET_PATH"] = socket_path
    for key in ("CMUX_SOCKET", "CMUX_SOCKET_PASSWORD", "CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "CMUX_TAB_ID"):
        env.pop(key, None)
    command = [cli, *args]
    if no_live_socket:
        command = ["/usr/bin/sandbox-exec", "-p", NO_LIVE_SOCKET_PROFILE, *command]
    return subprocess.run(command, text=True, capture_output=True, cwd=str(cwd) if cwd else None, env=env, timeout=20, check=False)


def local_time(ms: int) -> str:
    return time.strftime("%Y-%m-%d %H:%M", time.localtime(ms / 1000))


def write_global(home: Path, text: str) -> Path:
    path = home / ".config" / "cmux" / "cmux.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


def expected_list() -> list[str]:
    return [
        f"{NO_ROW}:",
        f"  claude  agent_needs_input    2 times, last seen {local_time(1795201320000)}",
        f"  kimi    plugin_notification  1 time, last seen {local_time(1795097700000)}",
        f"  grok    cm124_grok_type      1 time, last seen {local_time(1795056000000)}",
        "To map one, add this under agentEvents in ~/.config/cmux/cmux.json:",
        ROW,
    ]


def main() -> int:
    cli = resolve_cmux_cli()
    failures: list[str] = []

    def check(condition: bool, label: str, detail: str = "") -> None:
        if not condition:
            failures.append(f"{label}: {detail}")

    def lines(result: subprocess.CompletedProcess[str]) -> list[str]:
        return result.stdout.splitlines()

    with tempfile.TemporaryDirectory(prefix="cmux-doctor-ae-") as temp:
        home = Path(temp)
        missing = str(home / "missing.sock")

        # 1. No rows, no app: the verdict line, and the list says it isn't available.
        write_global(home, '{"schemaVersion": 1}')
        result = run_cli(cli, ["config", "doctor"], home, missing)
        out = lines(result)
        check(result.returncode == 0, "no rows, no app: exit", f"{result.returncode} {result.stderr}")
        check("  agentEvents: none; built-in rows only" in out, "no rows: agentEvents line", result.stdout)
        check(f"{NO_ROW}: cmux didn't answer, so this list isn't available" in out, "no app: list line", result.stdout)

        # 2. No rows, app answers an empty list.
        app = MockApp([])
        result = run_cli(cli, ["config", "doctor"], home, app.path)
        check(f"{NO_ROW}: none seen" in lines(result), "empty list: line", result.stdout)
        check(app.methods == ["agent_events.unmapped_types"], "empty list: one call", str(app.methods))
        app.close()

        # 3. One valid row and three unmapped types: padded columns, newest first, the paste line.
        write_global(home, '{"schemaVersion": 1, "agentEvents": [' + ROW + "]}")
        app = MockApp(TYPES)
        result = run_cli(cli, ["config", "doctor"], home, app.path)
        out = lines(result)
        check(result.returncode == 0, "valid row: exit", f"{result.returncode} {result.stderr}")
        check(any(line.startswith("OK primary:") for line in out), "valid row: OK primary", result.stdout)
        check("  agentEvents: 1 row, valid" in out, "valid row: verdict", result.stdout)
        start = out.index(f"{NO_ROW}:") if f"{NO_ROW}:" in out else -1
        check(start >= 0 and out[start:start + 6] == expected_list(), "list block", result.stdout)
        check("" in out[start - 1:start], "list is under its own blank line", result.stdout)
        app.close()

        # 4. A bad row: ERROR, the row's line, the not-applied line, the list still prints, exit 1.
        write_global(home, '{"agentEvents": [' + ROW + ', {"agent": "claude", "notification": "x", "means": "aprooval"}]}')
        app = MockApp(TYPES)
        result = run_cli(cli, ["config", "doctor"], home, app.path)
        out = lines(result)
        check(result.returncode == 1, "bad row: exit", str(result.returncode))
        check("Error: cmux config doctor found 1 error(s)" in result.stderr, "bad row: stderr", result.stderr)
        check(any(line.startswith("ERROR primary:") for line in out), "bad row: ERROR primary", result.stdout)
        check('  agentEvents[1]: means "aprooval": use question, approval, resolved or ignore' in out, "bad row: line", result.stdout)
        check("  agentEvents: this edit isn't applied; cmux keeps the last valid rows" in out, "bad row: not applied", result.stdout)
        check(expected_list()[1] in out, "bad row: list still prints", result.stdout)
        app.close()

        # 5. Every other rule's line, each at most 80 cells.
        cases = [
            ('[{"notification": "x", "means": "ignore"}]', '  agentEvents[0]: "agent" is missing; name one, such as "claude", or "*"'),
            ('[{"agent": "claude", "means": "ignore"}]', '  agentEvents[0]: "notification" is missing; name a type, such as "idle_prompt"'),
            ('[{"agent": "claude", "notification": "x"}]', '  agentEvents[0]: "means" is missing; use question, approval, resolved or ignore'),
            ('[{"agent": 3, "notification": "x", "means": "ignore"}]', '  agentEvents[0]: "agent" must be text, such as "claude"'),
            ("[" + ROW + "," + ROW + "]", "  agentEvents[1]: same agent and notification as agentEvents[0]; keep one"),
            ('[{"agent": "claude", "tool": "AskUserQuestion", "means": "question"}]',
             '  agentEvents[0]: "tool" isn\'t a row key; a row has agent, notification, means'),
            ('["claude"]', "  agentEvents[0]: a row must be an object"),
            ('{"agent": "claude"}', "  agentEvents: must be a list of rows"),
        ]
        for rows, expected in cases:
            write_global(home, '{"agentEvents": ' + rows + "}")
            result = run_cli(cli, ["config", "doctor"], home, missing)
            check(expected in lines(result), f"rule line {rows}", result.stdout)
            check(len(expected) <= 80, f"rule line fits 80 cells {rows}", str(len(expected)))
            check(result.returncode == 1, f"rule exit {rows}", str(result.returncode))

        # 6. A warning for an agent whose notifications never reach the table: exit 0, status stays OK.
        write_global(home, '{"agentEvents": [{"agent": "pi", "notification": "idle_prompt", "means": "ignore"}, ' + ROW + "]}")
        result = run_cli(cli, ["config", "doctor"], home, missing)
        out = lines(result)
        check(result.returncode == 0, "warning: exit", f"{result.returncode} {result.stderr}")
        check(any(line.startswith("OK primary:") for line in out), "warning: still OK", result.stdout)
        check("  agentEvents: 2 rows, valid" in out, "warning: verdict", result.stdout)
        check("  warning: agentEvents[0] does nothing: pi's notifications never reach it" in out, "warning: line", result.stdout)

        # 7. --json: the finding's agent_events and the top-level unmapped_types.
        write_global(home, '{"agentEvents": [' + ROW + "]}")
        app = MockApp(TYPES)
        result = run_cli(cli, ["--json", "config", "doctor"], home, app.path)
        payload = json.loads(result.stdout)
        finding = payload["findings"][0]
        check(finding.get("agent_events") == {"rows": 1, "valid": True, "issues": [], "warnings": []}, "json: agent_events", result.stdout)
        check(payload.get("unmapped_types") == TYPES, "json: unmapped_types", result.stdout)
        app.close()
        write_global(home, '{"agentEvents": [{"agent": "claude", "notification": "x", "means": "aprooval"}]}')
        result = run_cli(cli, ["--json", "config", "doctor"], home, missing)
        payload = json.loads(result.stdout)
        finding = payload["findings"][0]
        agent_events = finding.get("agent_events", {})
        check(agent_events.get("valid") is False and agent_events.get("rows") == 0, "json bad: valid false", result.stdout)
        check(agent_events.get("issues") == [{
            "index": 0, "rule": "badMeaning", "value": "aprooval",
            "message": 'agentEvents[0]: means "aprooval": use question, approval, resolved or ignore',
        }], "json bad: issues", result.stdout)
        check("unmapped_types" in payload and payload["unmapped_types"] is None, "json no app: null", result.stdout)

        # 8. An app that accepts and never answers: doctor gives up at its 2 s bound and says so.
        write_global(home, '{"agentEvents": [' + ROW + "]}")
        app = MockApp(TYPES, silent=True)
        started = time.monotonic()
        result = run_cli(cli, ["config", "doctor"], home, app.path)
        elapsed = time.monotonic() - started
        check(elapsed < 4.5, "slow app: bounded", f"{elapsed:.1f}s")
        check(f"{NO_ROW}: cmux didn't answer, so this list isn't available" in lines(result), "slow app: line", result.stdout)
        check(result.returncode == 0, "slow app: exit", str(result.returncode))
        app.close()

        # 9. A repo's own cmux.json with agentEvents: its finding stays OK and says rows there are ignored.
        write_global(home, "{}")
        repo = home / "work" / "repo"
        (repo / ".cmux").mkdir(parents=True)
        (repo / ".cmux" / "cmux.json").write_text('{"agentEvents": [' + ROW + "]}", encoding="utf-8")
        result = run_cli(cli, ["config", "doctor"], home, missing, cwd=repo)
        out = lines(result)
        check(result.returncode == 0, "repo file: exit", f"{result.returncode} {result.stderr}")
        check(any(line.startswith("OK project:") for line in out), "repo file: OK project", result.stdout)
        check("  agentEvents here is ignored; cmux reads rows only from ~/.config/cmux/cmux.json" in out, "repo file: ignored line", result.stdout)

        # 10. --path validates a file's rows too.
        custom = home / "custom.json"
        custom.write_text('{"agentEvents": [{"agent": "claude", "notification": "x", "means": "aprooval"}]}', encoding="utf-8")
        result = run_cli(cli, ["config", "doctor", "--path", str(custom)], home, missing)
        check(result.returncode == 1, "--path bad row: exit", str(result.returncode))
        check('  agentEvents[0]: means "aprooval": use question, approval, resolved or ignore' in lines(result), "--path bad row: line", result.stdout)

        # 12. The list is newest first whatever order the app answers in.
        write_global(home, '{"agentEvents": [' + ROW + "]}")
        app = MockApp(list(reversed(TYPES)))
        result = run_cli(cli, ["config", "doctor"], home, app.path)
        out = lines(result)
        start = out.index(f"{NO_ROW}:") if f"{NO_ROW}:" in out else -1
        check(start >= 0 and out[start:start + 6] == expected_list(), "scrambled answer: newest first", result.stdout)
        app.close()

        # 13. Doctor runs with no app, the way it always has. Three ways to have no app:
        #   (a) a socket pinned by the environment that does not exist, (b) one pinned by --socket, and (c) no pin at all with
        #   no live cmux anywhere (the sandbox hides every socket). (a) and (b) are never second-guessed by the CLI, so only
        #   (c) catches a doctor that is refused when discovery finds no live socket.
        for label, argv, pin in (
            ("pinned by environment", ["config", "doctor"], str(home / "nowhere.sock")),
            ("pinned by --socket", ["--socket", str(home / "nowhere.sock"), "config", "doctor"], None),
        ):
            result = run_cli(cli, argv, home, pin)
            check(result.returncode == 0, f"no app, {label}: exit", f"{result.returncode} {result.stderr}")
            check("OK primary:" in result.stdout, f"no app, {label}: the normal report", result.stdout)
            check(f"{NO_ROW}: cmux didn't answer, so this list isn't available" in lines(result), f"no app, {label}: list line", result.stdout)
        result = run_cli(cli, ["config", "doctor"], home, None, no_live_socket=True)
        check(result.returncode == 0, "no app, no pin, no live socket: exit", f"{result.returncode} {result.stderr}")
        check("OK primary:" in result.stdout, "no app, no pin: the normal report", result.stdout + result.stderr)
        check(f"{NO_ROW}: cmux didn't answer, so this list isn't available" in lines(result), "no app, no pin: list line", result.stdout + result.stderr)
        write_global(home, '{"agentEvents": [{"agent": "claude", "notification": "x", "means": "aprooval"}]}')
        result = run_cli(cli, ["config", "doctor"], home, None, no_live_socket=True)
        check(result.returncode == 1, "no app, no pin, bad row: the file's own exit code", f"{result.returncode} {result.stderr}")
        check("Error: cmux config doctor found 1 error(s)" in result.stderr, "no app, no pin, bad row: stderr", result.stderr)
        write_global(home, '{"agentEvents": [' + ROW + "]}")

        # 11. The list names no message text and the new lines fit 80 cells.
        write_global(home, '{"agentEvents": [' + ROW + "]}")
        app = MockApp(TYPES)
        result = run_cli(cli, ["config", "doctor"], home, app.path)
        new_lines = lines(result)
        start = new_lines.index(f"{NO_ROW}:") if f"{NO_ROW}:" in new_lines else None
        check(start is not None, "list heading present", result.stdout)
        for line in new_lines[start:start + 5] if start is not None else []:
            check(len(line) <= 80, "list line fits 80 cells", f"{len(line)}: {line}")
        app.close()

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1
    print("PASS: cmux config doctor validates agentEvents and lists unmapped notification types")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

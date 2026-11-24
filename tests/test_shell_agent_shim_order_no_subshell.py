#!/usr/bin/env python3
"""Regression: keeping the agent shims first on PATH must not fork a subshell.

cmux-rbf (#cm-128.8, #cm-142.1). `_cmux_keep_agent_shims_first` runs from the
zsh `precmd` and `chpwd` hooks. When something has moved the surface's shim
folder off the front of PATH, it moves it back. It used to rebuild PATH with a
command substitution, `PATH="$(_cmux_path_prepend_unique_directory ...)"`,
which forks a subshell on the prompt path. Upstream's #14847 removed that form
from the shim install for the same reason and added
`_cmux_path_prepend_unique_directory_into_reply`, which returns in `REPLY`.

The check wraps that REPLY core to record `$ZSH_SUBSHELL` each time it runs,
puts the shim root behind `/usr/bin:/bin`, and calls the hook twice. The first
call must move the shim folder to the front without a subshell; the second must
find it already first and do nothing. `test_shell_first_prompt_spawns.py` cannot
see this: it calls `_cmux_precmd` directly and watches for `/bin/rm` and
`/usr/bin/mktemp` only.
"""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ZSH_INTEGRATION = ROOT / "Resources" / "shell-integration" / "cmux-zsh-integration.zsh"


def run_probe(directory: Path) -> tuple[str, list[str], str]:
    shim_root = directory / "cmux-cli-shims" / "surface-x"
    shim_root.mkdir(parents=True)
    log = directory / "calls.log"
    script = f"""
source {str(ZSH_INTEGRATION)!r} >/dev/null 2>&1
functions[_cmux_test_into_reply]=$functions[_cmux_path_prepend_unique_directory_into_reply]
_cmux_path_prepend_unique_directory_into_reply() {{
    print -r -- "subshell=$ZSH_SUBSHELL" >> {str(log)!r}
    _cmux_test_into_reply "$@"
}}
export CMUX_CLAUDE_WRAPPER_SHIM_ROOT={str(shim_root)!r}
PATH=/usr/bin:/bin
_cmux_keep_agent_shims_first
print -r -- "first=$PATH"
_cmux_keep_agent_shims_first
print -r -- "second=$PATH"
"""
    result = subprocess.run(
        ["/bin/zsh", "-f", "-c", script],
        env={
            "HOME": str(directory),
            "TMPDIR": str(directory),
            "PATH": "/usr/bin:/bin",
            "CMUX_SHELL_INTEGRATION": "1",
            "TERM": "xterm-256color",
        },
        cwd=str(directory),
        capture_output=True,
        text=True,
        timeout=20,
        check=False,
    )
    if result.returncode != 0:
        raise AssertionError(
            f"zsh exited {result.returncode}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr[-4000:]}"
        )
    calls = log.read_text().split() if log.exists() else []
    return result.stdout, calls, str(shim_root)


def main() -> int:
    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="cmux-shim-order-", dir="/tmp") as temp:
        stdout, calls, shim_root = run_probe(Path(temp))
    expected_path = f"{shim_root}:/usr/bin:/bin"
    lines = dict(line.split("=", 1) for line in stdout.splitlines() if "=" in line)
    if lines.get("first") != expected_path:
        failures.append(f"first call: PATH is {lines.get('first')!r}, expected {expected_path!r}")
    if lines.get("second") != expected_path:
        failures.append(f"second call: PATH is {lines.get('second')!r}, expected {expected_path!r}")
    if calls != ["subshell=0"]:
        failures.append(
            "the prepend must run once, in the prompt's own shell (subshell=0); "
            f"saw {calls or 'no call'}"
        )

    if failures:
        print("FAIL:")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print("PASS: the agent shims move to the front of PATH without a subshell")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

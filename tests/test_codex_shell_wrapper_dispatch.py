#!/usr/bin/env python3
"""Behavioral coverage for Codex dispatch in cmux-integrated shells."""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_SHELL_DIR = ROOT / "Resources" / "shell-integration"


def write_executable(path: Path, contents: str) -> None:
    path.write_text(contents, encoding="utf-8")
    path.chmod(0o755)


def read_lines(path: Path) -> list[str]:
    if not path.exists():
        return []
    return path.read_text(encoding="utf-8").splitlines()


def prepare_bundle(tmp: Path) -> tuple[Path, Path]:
    shell_dir = tmp / "bundle" / "Resources" / "shell-integration"
    bin_dir = tmp / "bundle" / "Resources" / "bin"
    shell_dir.mkdir(parents=True)
    bin_dir.mkdir(parents=True)

    shutil.copy2(SOURCE_SHELL_DIR / "cmux-zsh-integration.zsh", shell_dir)
    shutil.copy2(SOURCE_SHELL_DIR / "cmux-bash-integration.bash", shell_dir)
    (shell_dir / "fish").mkdir()
    shutil.copy2(SOURCE_SHELL_DIR / "fish" / "config.fish", shell_dir / "fish")
    return shell_dir, bin_dir


def base_environment(
    shell_dir: Path,
    real_bin: Path,
    shim: Path,
    wrapper: Path,
    user_codex: Path,
    log_path: Path,
) -> dict[str, str]:
    env = dict(os.environ)
    env.update(
        {
            "CMUX_SHELL_INTEGRATION_DIR": str(shell_dir),
            "CMUX_CODEX_WRAPPER_SHIM": str(shim),
            "CMUX_CODEX_WRAPPER_SHIM_ROOT": str(shim.parent),
            "CMUX_TEST_CODEX_WRAPPER": str(wrapper),
            "CMUX_TEST_USER_CODEX": str(user_codex),
            "CMUX_TEST_REAL_BIN": str(real_bin),
            "CMUX_TEST_LOG": str(log_path),
            "PATH": f"{real_bin}:/usr/bin:/bin",
        }
    )
    env.pop("GHOSTTY_BIN_DIR", None)
    return env


def run(
    argv: list[str],
    env: dict[str, str],
    log_path: Path,
) -> tuple[int, str, list[str]]:
    result = subprocess.run(
        argv,
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    output = ((result.stdout or "") + (result.stderr or "")).strip()
    return result.returncode, output, read_lines(log_path)


def zsh_case(
    shell_dir: Path,
    env: dict[str, str],
    log_path: Path,
    script: str,
    prelude: str = "",
) -> tuple[int, str, list[str]]:
    command = f'{prelude}\nsource "{shell_dir / "cmux-zsh-integration.zsh"}"\n{script}'
    return run(["zsh", "-fic", command], env, log_path)


def bash_case(
    shell_dir: Path,
    env: dict[str, str],
    log_path: Path,
    script: str,
    prelude: str = "",
) -> tuple[int, str, list[str]]:
    command = f'{prelude}\nsource "{shell_dir / "cmux-bash-integration.bash"}"\n{script}'
    return run(["bash", "--noprofile", "--norc", "-ic", command], env, log_path)


def fish_case(
    shell_dir: Path,
    env: dict[str, str],
    log_path: Path,
    script: str,
    prelude: str = "",
) -> tuple[int, str, list[str]] | None:
    fish = shutil.which("fish")
    if fish is None:
        return None
    commands = [prelude] if prelude else []
    commands.extend([f'source "{shell_dir / "fish" / "config.fish"}"', script])
    command = "; ".join(commands)
    return run([fish, "--no-config", "-c", command], env, log_path)


def record_case(
    failures: list[str],
    name: str,
    result: tuple[int, str, list[str]] | None,
    expected: list[str],
) -> None:
    if result is None:
        print(f"SKIP: {name}: fish is not installed")
        return
    rc, output, lines = result
    if rc != 0:
        failures.append(f"{name} exited non-zero rc={rc}: {output}")
    elif lines != expected:
        failures.append(f"{name} expected {expected!r}, saw {lines!r}")


def main() -> int:
    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="cmux-codex-shell-dispatch-") as td:
        tmp = Path(td)
        shell_dir, bundle_bin = prepare_bundle(tmp)
        real_bin = tmp / "real-bin"
        shim_root = tmp / "cmux-cli-shims" / "surface-1"
        real_bin.mkdir(parents=True)
        shim_root.mkdir(parents=True)

        wrapper = bundle_bin / "cmux-codex-wrapper"
        shim = shim_root / "codex"
        user_codex = real_bin / "user-codex"
        write_executable(
            wrapper,
            """#!/bin/sh
set -eu
printf 'wrapper:%s\n' "$*" >> "$CMUX_TEST_LOG"
""",
        )
        write_executable(
            shim,
            """#!/bin/sh
set -eu
exec "$CMUX_TEST_CODEX_WRAPPER" "$@"
""",
        )
        write_executable(
            real_bin / "codex",
            """#!/bin/sh
set -eu
printf 'real:%s\n' "$*" >> "$CMUX_TEST_LOG"
""",
        )
        write_executable(
            user_codex,
            """#!/bin/sh
set -eu
printf 'user:%s\n' "$*" >> "$CMUX_TEST_LOG"
""",
        )

        def env_for(name: str) -> tuple[dict[str, str], Path]:
            log_path = tmp / f"{name}.log"
            return (
                base_environment(shell_dir, real_bin, shim, wrapper, user_codex, log_path),
                log_path,
            )

        env, log_path = env_for("zsh-path")
        record_case(
            failures,
            "zsh PATH mutation",
            zsh_case(
                shell_dir,
                env,
                log_path,
                'PATH="$CMUX_TEST_REAL_BIN:$PATH"; codex zsh-path',
            ),
            ["wrapper:zsh-path"],
        )

        env, log_path = env_for("bash-path")
        record_case(
            failures,
            "bash PATH mutation",
            bash_case(
                shell_dir,
                env,
                log_path,
                'PATH="$CMUX_TEST_REAL_BIN:$PATH"; codex bash-path',
            ),
            ["wrapper:bash-path"],
        )

        env, log_path = env_for("fish-path")
        record_case(
            failures,
            "fish PATH mutation",
            fish_case(
                shell_dir,
                env,
                log_path,
                'set -gx PATH "$CMUX_TEST_REAL_BIN" $PATH; codex fish-path',
            ),
            ["wrapper:fish-path"],
        )

        env, log_path = env_for("zsh-codex-sx")
        record_case(
            failures,
            "zsh alias expanding to bare codex",
            zsh_case(
                shell_dir,
                env,
                log_path,
                "alias codex-sx='codex --model gpt-test'; "
                'PATH="$CMUX_TEST_REAL_BIN:$PATH"; eval "codex-sx prompt"',
            ),
            ["wrapper:--model gpt-test prompt"],
        )

        env, log_path = env_for("bash-codex-sx")
        record_case(
            failures,
            "bash alias expanding to bare codex",
            bash_case(
                shell_dir,
                env,
                log_path,
                "alias codex-sx='codex --model gpt-test'; "
                'PATH="$CMUX_TEST_REAL_BIN:$PATH"; eval "codex-sx prompt"',
            ),
            ["wrapper:--model gpt-test prompt"],
        )

        env, log_path = env_for("zsh-user-function")
        record_case(
            failures,
            "zsh replacement function",
            zsh_case(
                shell_dir,
                env,
                log_path,
                'codex() { "$CMUX_TEST_USER_CODEX" "$@"; }; _cmux_fix_path; '
                'codex zsh-user-function',
            ),
            ["user:zsh-user-function"],
        )

        env, log_path = env_for("zsh-user-alias")
        record_case(
            failures,
            "zsh replacement alias",
            zsh_case(
                shell_dir,
                env,
                log_path,
                'alias codex="$CMUX_TEST_USER_CODEX"; _cmux_fix_path; '
                'eval "codex zsh-user-alias"',
            ),
            ["user:zsh-user-alias"],
        )

        env, log_path = env_for("bash-user-function")
        record_case(
            failures,
            "bash replacement function",
            bash_case(
                shell_dir,
                env,
                log_path,
                'codex bash-user-function',
                'codex() { "$CMUX_TEST_USER_CODEX" "$@"; }',
            ),
            ["user:bash-user-function"],
        )

        env, log_path = env_for("bash-user-alias")
        record_case(
            failures,
            "bash replacement alias",
            bash_case(
                shell_dir,
                env,
                log_path,
                'eval "codex bash-user-alias"',
                'alias codex="$CMUX_TEST_USER_CODEX"',
            ),
            ["user:bash-user-alias"],
        )

        env, log_path = env_for("fish-user-function")
        record_case(
            failures,
            "fish replacement function",
            fish_case(
                shell_dir,
                env,
                log_path,
                'codex fish-user-function',
                'function codex; "$CMUX_TEST_USER_CODEX" $argv; end',
            ),
            ["user:fish-user-function"],
        )

        env, log_path = env_for("zsh-stale-shim")
        env["CMUX_CODEX_WRAPPER_SHIM"] = str(tmp / "missing" / "codex")
        record_case(
            failures,
            "zsh bundled-wrapper fallback",
            zsh_case(shell_dir, env, log_path, "codex zsh-stale-shim"),
            ["wrapper:zsh-stale-shim"],
        )

        env, log_path = env_for("zsh-command-bypass")
        record_case(
            failures,
            "zsh command bypass",
            zsh_case(
                shell_dir,
                env,
                log_path,
                'PATH="$CMUX_TEST_REAL_BIN:$PATH"; command codex zsh-command-bypass',
            ),
            ["real:zsh-command-bypass"],
        )

    if failures:
        print("FAIL: supported shells did not preserve Codex dispatch ownership")
        for failure in failures:
            print(f"- {failure}")
        return 1

    shells = "zsh, bash, and fish" if shutil.which("fish") else "zsh and bash (fish not installed)"
    print(f"PASS: {shells} preserve Codex dispatch ownership")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

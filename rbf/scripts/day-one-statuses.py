#!/usr/bin/env python3
"""Give each workspace that wears the color of one of your statuses that status. (#cm-109.2)

Run it with no flag first. That is the dry run: it prints one line for each workspace it would
change and changes nothing. It ends by printing the whole command that applies the list, so you
can read the list, then copy that line to approve it.

    python3 rbf/scripts/day-one-statuses.py                   # dry run
    python3 rbf/scripts/day-one-statuses.py --apply --app <bundle id>

It asks the app which app it is (`<cli> identify`). `--app` must equal that answer.
It never changes a color and never sets a status on a workspace while an agent waits there.
It sets one of cmux's own statuses (done, review) only where no agent runs and none waits.
"""

import argparse
import json
import os
import shlex
import subprocess
import sys

CMUX_STATUS_IDS = {"todo", "working", "needs-attention", "review", "done"}


class Stop(Exception):
    """The script stops with a message and exits with a failure."""


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", help="the bundle id of the app you mean; required with --apply")
    parser.add_argument("--apply", action="store_true", help="make the changes")
    parser.add_argument("--cli", help="the cmux to run (default: CMUX_BUNDLED_CLI_PATH, then cmux on PATH)")
    args = parser.parse_args()
    if args.apply and not args.app:
        parser.error("--apply needs --app <bundle id>")
    try:
        return Run(args).run()
    except Stop as stop:
        print(f"stopped: {stop}")
        return 1


class Run:
    def __init__(self, args):
        self.args = args
        self.cli = args.cli or os.environ.get("CMUX_BUNDLED_CLI_PATH") or "cmux"
        self.counts = {
            "set": 0, "already": 0, "waiting": 0, "running": 0, "share": 0, "nomatch": 0, "nocolor": 0,
        }
        self.failed = False

    # ---- the CLI -----------------------------------------------------------------------------

    def read(self, *words):
        try:
            done = subprocess.run([self.cli, *words], capture_output=True, text=True, timeout=60)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise Stop(f"could not run {self.cli} {' '.join(words)}: {error}")
        if done.returncode != 0:
            detail = (done.stderr or done.stdout).strip()
            raise Stop(f"{self.cli} {' '.join(words)} failed: {detail}")
        try:
            return json.loads(done.stdout)
        except ValueError:
            raise Stop(f"{self.cli} {' '.join(words)} did not answer JSON")

    def status_list(self):
        answer = self.read("workspace", "status", "list", "--json")
        return {
            "controls_enabled": answer.get("controls_enabled"),
            "source": answer.get("source"),
            "problems": answer.get("problems") or [],
            "statuses": answer.get("statuses") or [],
        }

    def workspaces(self):
        found, seen = [], set()
        for window in self.read("list-windows", "--json"):
            for ws in self.read("workspace", "list", "--json", "--window", str(window["id"])).get("workspaces") or []:
                if ws.get("id") in seen:
                    continue
                seen.add(ws.get("id"))
                found.append(ws)
        return found

    def workspace_status(self, ws, *words):
        """One status read (or the answer of a set), checked to be about the workspace asked for."""
        # --id-format both: the CLI's default (refs) drops workspace_id from the answer whenever workspace_ref is there
        answer = self.read("workspace", "status", *words, "--workspace", ws["id"], "--id-format", "both", "--json")
        # rule 2: a ref the app does not know can resolve to the selected workspace and answer success
        if "workspace_id" not in answer:
            raise Stop(f"the status answer for {ws.get('ref', ws['id'])} has no workspace_id, so it cannot be checked; nothing more was set")
        if str(answer["workspace_id"]).lower() != str(ws["id"]).lower():
            raise Stop(f"the status answer for {ws.get('ref', ws['id'])} is about another workspace; nothing more was set")
        return answer

    # ---- the run -----------------------------------------------------------------------------

    def run(self):
        identity = self.read("identify")
        app = identity.get("bundle_identifier")
        if not app:
            raise Stop("the app's answer to identify has no bundle_identifier")
        if self.args.app and self.args.app != app:
            raise Stop(f"--app is {self.args.app}, but the app answered {app}; nothing was set")

        listing = self.status_list()
        if not listing["controls_enabled"]:
            raise Stop(f"the status controls are off in {app}, so a status set now would not show; switch them on and run again")
        if listing["source"] == "cmux":
            raise Stop(f"{app} has no status list of yours (it uses cmux's five), so there is nothing to match")
        statuses = listing["statuses"]
        print(f"app: {app}   statuses: on   list: {listing['source']}, {len(statuses)} statuses")
        for problem in listing["problems"]:
            print(f"problem: {problem.get('message') or problem.get('code')}")

        by_color = {}
        for status in statuses:
            hex_ = normalize(status.get("color_hex"))
            if hex_:
                by_color.setdefault(hex_, []).append(status)

        for ws in self.workspaces():
            color = normalize(ws.get("custom_color"))
            if not color:
                self.counts["nocolor"] += 1
                continue
            matches = by_color.get(color)
            if not matches:
                self.counts["nomatch"] += 1
                continue
            head = f'{ws.get("ref") or ws["id"]}   "{one_line(ws.get("title"))}"   color {ws["custom_color"].strip().upper()}'
            if len(matches) > 1:
                ids = [m["id"] for m in matches]
                names = ", ".join(ids[:-1]) + f" and {ids[-1]}"
                print(f"{head}   not set: {names} share this color")
                self.counts["share"] += 1
                continue
            if not self.line(ws, matches[0], head):
                break

        c = self.counts
        print(
            f"set {c['set']} · already {c['already']} · skipped, agent waiting {c['waiting']}"
            f" · skipped, agent running {c['running']} · two statuses share the color {c['share']}"
            f" · no matching color {c['nomatch']} · no color {c['nocolor']}"
        )
        if not self.args.apply:
            parts = ["python3", sys.argv[0]]
            if self.args.cli:
                parts += ["--cli", self.args.cli]
            parts += ["--apply", "--app", app]
            print(" ".join(shlex.quote(p) for p in parts))
            return 0
        return 1 if self.failed else 0

    def line(self, ws, status, head):
        """Print one workspace's line. Returns False when the run must stop here."""
        apply = self.args.apply
        target = status["id"]
        after = status["color_hex"].strip().upper()
        if apply and not self.color_still_matches(ws, target):  # rule 9
            before = self.workspace_status(ws)
            print(f"{head} → {after}   status {before.get('status_id') or 'auto'} → {target}   refused: the color would change")
            self.failed = True
            return False
        answer = self.workspace_status(ws)
        before = answer.get("status_id") or "auto"
        signals = answer.get("signals") or {}
        waiting = bool(signals.get("any_agent_needs_input"))
        running = bool(signals.get("any_agent_running"))
        head = f"{head} → {after}   status {before} → {target}"
        if before == target:  # rule 7
            print(f"{head}   already {target}")
            self.counts["already"] += 1
        elif waiting:  # rule 4
            print(f"{head}   {'skipped' if apply else 'would skip'}: an agent is waiting")
            self.counts["waiting"] += 1
        elif running and target in CMUX_STATUS_IDS:  # rule 5
            print(f"{head}   {'skipped' if apply else 'would skip'}: an agent is running")
            self.counts["running"] += 1
        elif not apply:
            print(f"{head}   would set")
            self.counts["set"] += 1
        else:
            result = self.workspace_status(ws, "set", target)  # rule 6
            signals = result.get("signals") or {}
            note = "set"
            if signals.get("any_agent_needs_input"):
                note = "set while an agent was waiting"
            elif signals.get("any_agent_running") and target in CMUX_STATUS_IDS:
                note = "set while an agent was running"
            if note != "set":
                self.failed = True
            print(f"{head}   {note}")
            self.counts["set"] += 1
        return True

    def color_still_matches(self, ws, target):
        """rule 9: just before a set, the status's color is still the color the workspace wears."""
        status = next((s for s in self.status_list()["statuses"] if s["id"] == target), None)
        fresh = next((w for w in self.workspaces() if w.get("id") == ws["id"]), None)
        if status is None or fresh is None:
            raise Stop(f"{ws.get('ref', ws['id'])} or the status {target} changed since the first read; run the dry run again")
        return normalize(status.get("color_hex")) == normalize(fresh.get("custom_color"))


def normalize(color):
    return color.strip().lower() if isinstance(color, str) and color.strip() else None


def one_line(text):
    return " ".join(str(text or "").split())


if __name__ == "__main__":
    sys.exit(main())

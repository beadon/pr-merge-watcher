#!/usr/bin/env python3
"""pr-event-watcher.py — wait for GitHub PRs to merge or fail, without polling.

Copyright (C) 2026 beadon. GPL-3.0-or-later; see LICENSE.

Subscribes to the repo's webhook events through `gh webhook forward` (the
`cli/gh-webhook` extension) and exits on the first terminal event for every
watched PR. It never polls: the only GitHub API reads are one snapshot per PR
at startup, so a check that finished before the subscription opened is not
missed.

Terminal states, per PR:
  MERGED   pull_request closed with merged=true
  CLOSED   pull_request closed without merging
  FAILED   any check run on the PR's current head completed with
           failure / timed_out / action_required / startup_failure.
           Reported with whether the check is required by branch protection.
  PASSED   (only with --until-workflow NAME) that workflow completed with
           success on the PR's current head. Use it for a PR without
           auto-merge, where "merged" would never arrive on its own.

Non-terminal events are logged as they arrive: check results, new pushes
(`synchronize`, which moves the tracked head SHA), and cancelled runs. A
cancelled check whose name is in --rerun-cancelled is rerun automatically
(the concurrency-lock case pr-merge-watcher.sh also handles).

Usage:
  pr-event-watcher.py --repo OWNER/NAME [--timeout SECS]
                      [--until-workflow NAME] [--rerun-cancelled NAME ...]
                      PR [PR ...]

Exit codes: 0 all merged (or PASSED) · 3 at least one FAILED · 4 at least one CLOSED
unmerged (and none failed) · 1 timeout or forwarder error · 2 usage error.

Requires: gh (authenticated, repo admin for webhook creation) and the
cli/gh-webhook extension (`gh extension install cli/gh-webhook`).
GitHub allows one active `gh webhook forward` per repo, so run one watcher
per repo and pass it every PR you care about.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import threading
import time

__version__ = "0.2.0"

FAIL_CONCLUSIONS = {"failure", "timed_out", "action_required", "startup_failure"}


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def gh_json(args: list[str]) -> object:
    out = subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout
    return json.loads(out) if out.strip() else None


class PR:
    def __init__(self, number: int) -> None:
        self.number = number
        self.head_sha = ""
        self.required: set[str] = set()
        self.final: str | None = None


def snapshot(repo: str, pr: PR) -> None:
    """One read at startup: head SHA, merge state, required checks, finished failures."""
    info = gh_json(["pr", "view", str(pr.number), "--repo", repo, "--json", "state,headRefOid"])
    pr.head_sha = info["headRefOid"]
    if info["state"] == "MERGED":
        pr.final = "MERGED"
        log(f"PR #{pr.number}: MERGED (before watch started)")
        return
    if info["state"] == "CLOSED":
        pr.final = "CLOSED"
        log(f"PR #{pr.number}: CLOSED unmerged (before watch started)")
        return
    try:
        req = gh_json(["pr", "checks", str(pr.number), "--repo", repo, "--required", "--json", "name"])
        pr.required = {c["name"] for c in req or []}
    except subprocess.CalledProcessError:
        pr.required = set()  # no required checks reported yet
    try:
        checks = gh_json(["pr", "checks", str(pr.number), "--repo", repo, "--json", "name,bucket"]) or []
    except subprocess.CalledProcessError:
        checks = []  # no checks registered yet; events will report them
    failed = [c["name"] for c in checks if c.get("bucket") == "fail"]
    if failed:
        fail(pr, failed[0], "already failed before watch started")
    else:
        log(f"PR #{pr.number}: watching head {pr.head_sha[:8]} ({len(checks)} checks so far)")


def fail(pr: PR, name: str, detail: str) -> None:
    kind = "REQUIRED" if name in pr.required else "non-required"
    pr.final = "FAILED"
    log(f"PR #{pr.number}: FAILED — '{name}' ({kind}) {detail}")


def handle(event: dict, prs: dict[int, PR], repo: str, rerun_names: set[str],
           until_workflows: set[str]) -> None:
    if "pull_request" in event and "number" in event:
        pr = prs.get(event["number"])
        if not pr or pr.final:
            return
        action = event.get("action")
        if action == "synchronize":
            pr.head_sha = event["pull_request"]["head"]["sha"]
            log(f"PR #{pr.number}: new head {pr.head_sha[:8]} — tracking its checks")
        elif action == "closed":
            pr.final = "MERGED" if event["pull_request"].get("merged") else "CLOSED"
            log(f"PR #{pr.number}: {pr.final}")
        return

    wf = event.get("workflow_run")
    if wf and event.get("action") == "completed" and wf["name"] in until_workflows:
        for pr in prs.values():
            if not pr.final and wf["head_sha"] == pr.head_sha and wf.get("conclusion") == "success":
                pr.final = "PASSED"
                log(f"PR #{pr.number}: PASSED — workflow '{wf['name']}' succeeded on {pr.head_sha[:8]}")
        return

    run = event.get("check_run")
    if not run or event.get("action") != "completed":
        return
    sha, name, conclusion = run["head_sha"], run["name"], run.get("conclusion")
    for pr in prs.values():
        if pr.final or sha != pr.head_sha:
            continue
        if conclusion in FAIL_CONCLUSIONS:
            fail(pr, name, f"({conclusion}) {run.get('html_url', '')}")
        elif conclusion == "cancelled":
            match = re.search(r"/runs/(\d+)", run.get("details_url") or "")
            if name in rerun_names and match:
                log(f"PR #{pr.number}: '{name}' cancelled — rerunning run {match.group(1)}")
                subprocess.run(["gh", "run", "rerun", match.group(1), "--repo", repo, "--failed"],
                               capture_output=True)
            else:
                log(f"PR #{pr.number}: '{name}' cancelled (usually superseded by a newer push)")
        else:
            log(f"PR #{pr.number}: '{name}' {conclusion}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    ap.add_argument("--repo", required=True)
    ap.add_argument("--timeout", type=int, default=3600)
    ap.add_argument("--until-workflow", action="append", default=[], metavar="WORKFLOW_NAME")
    ap.add_argument("--rerun-cancelled", action="append", default=[], metavar="CHECK_NAME")
    ap.add_argument("prs", nargs="+", type=int)
    args = ap.parse_args()

    prs = {n: PR(n) for n in args.prs}
    for pr in prs.values():
        snapshot(args.repo, pr)

    def done() -> bool:
        return all(p.final for p in prs.values())

    if not done():
        fwd = subprocess.Popen(
            ["gh", "webhook", "forward", "--repo", args.repo,
             "--events", "check_run,workflow_run,pull_request"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        threading.Timer(args.timeout, fwd.terminate).start()
        try:
            for line in fwd.stdout:  # one JSON payload per line; blocks until an event arrives
                line = line.strip()
                if not line.startswith("{"):
                    continue
                try:
                    handle(json.loads(line), prs, args.repo, set(args.rerun_cancelled),
                           set(args.until_workflow))
                except (KeyError, json.JSONDecodeError) as exc:
                    log(f"skipped unparseable event: {exc}")
                if done():
                    break
        finally:
            fwd.terminate()  # gh removes its temporary webhook on exit
            try:
                fwd.wait(timeout=10)
            except subprocess.TimeoutExpired:
                fwd.kill()
        if not done():
            err = (fwd.stderr.read() or "").strip().splitlines()[-3:] if fwd.stderr else []
            log("TIMEOUT or forwarder exited — unresolved: "
                + " ".join(f"#{p.number}" for p in prs.values() if not p.final)
                + (f" | gh: {' / '.join(err)}" if err else ""))
            return 1

    finals = [p.final for p in prs.values()]
    if "FAILED" in finals:
        return 3
    if "CLOSED" in finals:
        return 4
    log("ALL_MERGED" if all(f == "MERGED" for f in finals) else "ALL_DONE (merged or passed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

# AGENTS.md — using pr-merge-watcher

This file is for an AI coding agent that has just been told to use this tool,
not for a human reading the README for context. If you're an agent and
someone pointed you at `beadon/pr-merge-watcher`, read this file top to
bottom before invoking anything.

## When to reach for this, and when not to

You have three options when you need a PR to land, roughly in order of how
much machinery they need:

1. **You opened one PR and just need to know when its checks are done.**
   Use `gh` directly, no script needed:
   ```bash
   gh pr checks <pr> --repo <owner/repo> --watch --fail-fast
   ```
   This blocks until every check on that PR resolves and exits non-zero if
   one fails. That's it. Don't reach for this repo for that case.

2. **You have several PRs open against a base branch that other people or
   agents are also merging into, with `gh pr merge --auto` already enabled
   on each, and you need to know when they've all landed.** This is the
   actual case this script is for. Use it.

3. **A PR is stuck and you don't know why.** Run this script (or just
   `gh pr view <pr> --json mergeable,mergeStateStatus`) before assuming
   anything — see "Reading the output" below for what each state means and
   what, if anything, you should do about it.

## Why case 2 needs more than `gh pr checks --watch`

Two things go wrong that a bare watch loop over check status won't catch:

- **A CI job bound to exclusive infrastructure gets cancelled, not failed.**
  If the target repo's CI has a job using a `concurrency` group with
  `cancel-in-progress: true` (very common for E2E suites that need fixed
  ports, or any job that talks to a shared/singleton resource), then two PRs
  pushing within the same window cause GitHub to cancel the older run. That
  run reports `FAILURE`, identically to a real test failure, unless you go
  look at the run's own log for a cancellation marker. If you are yourself
  pushing several PRs in a short window (e.g. you just did a
  merge-latest-development-and-push pass across 5 branches back to back),
  **expect this** — it is the normal, not the exceptional, case.

- **A real merge conflict does not page anyone.** `gh pr merge --auto`
  degrades silently to "nothing happens" when a PR becomes unmergeable. If
  you are only polling `gh pr view --json state`, a PR can sit unmerged
  indefinitely with zero signal beyond "still open" — and if the base branch
  is moving fast (several PRs merging per hour from you or other agents),
  a PR that was clean an hour ago can become `CONFLICTING` between two of
  your checks. You have to poll `mergeable`/`mergeStateStatus` specifically,
  not just `state`, to catch this.

## Running it

```bash
./pr-merge-watcher.sh --watch-check "<your CI's E2E-or-similar job name>" \
  247 253 257 258
```

- Run it from inside the target repo, or pass `--repo owner/name`.
- `--watch-check` must match a check's exact display name as `gh pr checks`
  shows it. If you don't know the name yet, run `gh pr checks <one-pr>`
  once first and copy the name of whichever job is bound to exclusive
  infrastructure in that repo's CI.
- If the target CI reports cancellations with different wording than
  `canceling|cancelled` in the run log/annotations, pass
  `--cancel-pattern` — check by running `gh run view <a-known-cancelled-run-id>`
  once and reading what it actually says.
- It runs in the foreground and blocks until every PR you gave it is
  `MERGED`, or `--timeout` (default 1800s) elapses. If you need to keep
  working while it runs, background it the way your harness supports doing
  that (e.g. a `Bash` tool's `run_in_background`, or a `Monitor`-style
  primitive if your harness has one) rather than blocking your own turn on
  it — this script's whole point is that you don't have to babysit the poll
  loop yourself.

## Reading the output

Every line is one event, timestamped. The ones that mean "keep waiting,
nothing needed from you":

```
PR #257 mergeable: BEHIND
PR #257 check 'E2E Tests (Chromium)': PENDING
PR #257: 'E2E Tests (Chromium)' was cancelled (concurrency lock) — rerunning
PR #257: MERGED
```

The ones that mean **stop and act**:

```
PR #257 mergeable: CONFLICTING
PR #257: REAL CONFLICT — needs manual resolution, not auto-handled
```
→ Go resolve it yourself (see "Resolving a real conflict" below). The
script will keep reporting `CONFLICTING` on every poll until you fix it; it
will never do this for you.

```
PR #258: 'E2E Tests (Chromium)' genuinely failed — needs investigation
```
→ The failing run had no cancellation marker. Go read the actual log
(`gh run view <run-id> --log-failed`) — this is a real problem, not a queue
artifact, and rerunning it blindly wastes CI time and hides the real cause.
Also check for check names *other* than the one you told the script to
watch — a duplicate-migration-revision-ID collision, for instance, shows up
as a different named check failing (e.g. "Check Alembic Heads") and this
script won't specifically call that out unless you also pass it as a
`--watch-check`; when in doubt, run `gh pr checks <pr>` yourself once you
see anything you don't recognize.

## Resolving a real conflict

This script will never do this part — it's telling you a human-judgment
step is needed, not doing that step. The pattern that actually works,
proven across ~10 tickets landing against a fast-moving base branch in one
session:

```bash
cd <your worktree for that PR's branch>
git fetch origin
git merge origin/development --no-edit   # or your repo's base branch name
# resolve conflict markers by hand -- read both sides, understand what each
# one was trying to do, keep both if they're additive (very common: two
# unrelated features both added a line near each other), reconcile properly
# if they're not (e.g. one side extracted a helper the other side's new
# code needs to call into, not two competing inline implementations)
git add <resolved files>
git commit --no-edit
# re-run your test suite / typecheck / lint on the resolved files before push
git push
```

**Before you push**, fetch once more and check whether your *own remote
branch* moved out from under you — some `gh pr merge --auto` setups will
push an "Update branch" merge commit directly to your PR branch on GitHub's
own initiative when it detects the branch fell behind:

```bash
git fetch origin
git log --oneline HEAD..origin/<your-branch-name>
# if non-empty, merge it in before pushing, don't force-push over it
```

If the conflict is a duplicate revision/migration ID rather than a text
conflict (two branches independently created a migration with the same
numeric ID), the fix is different: rename yours to the next free ID and
re-point its parent — do not try to text-merge two migration files into one.

## Multiple agents/sessions working the same base branch

If you're one of several agents landing PRs against the same branch (this is
exactly the situation this tool was built in), two extra things matter:

- **Push one PR fully to merged before starting the next**, when you can.
  Racing several `merge origin/development && push` cycles across branches
  you own at the same time just means each push invalidates the next, and
  you spend more time re-merging than if you'd gone one at a time.
- **Don't touch a PR/branch you don't own** just because it showed up
  `CONFLICTING` or `BEHIND` in this script's output — that's someone else's
  (or another agent's) ticket. Only resolve conflicts on branches you
  yourself pushed.

## Requirements

`gh` (authenticated against the target repo) and `jq`. Nothing else.

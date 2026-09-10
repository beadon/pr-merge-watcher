# pr-merge-watcher

A small bash script that watches a set of GitHub PRs through CI and merge,
distinguishing two things that look identical from a naive poll loop but need
completely different responses:

1. **A CI job failed because of concurrency contention, not because your code
   is broken.** If your CI has a job bound to exclusive infrastructure — E2E
   tests against fixed ports, a shared test database, anything with a
   `concurrency` group and `cancel-in-progress: true` — then pushing several
   PRs close together causes GitHub to cancel all but the latest run in that
   group. Every PR but one comes back "failed." It isn't a real failure; it's
   a queue. The fix is to rerun it, not to investigate it.

2. **A real merge conflict (or a duplicate migration revision ID, or any
   other genuine blocker) is silently sitting there.** `gh pr merge --auto`
   degrades gracefully to "nothing happens" when a PR can't merge — it
   doesn't page anyone. If you're coordinating several PRs and only checking
   `gh pr view --json state`, you can watch a PR sit un-merged for a long time
   without any signal of *why*, because you're not the one who'll notice the
   conflict banner on the PR page.

This script was built out of exactly that situation: several tickets landing
against a fast-moving base branch (some from one coordinating agent, some
from parallel sessions), where both failure modes showed up in the same
afternoon and needed to be told apart quickly.

## What it does

Polls a list of PR numbers on an interval. For each:

- Reports `MERGED` once GitHub says so, then stops watching that PR.
- Reports every transition of the PR's `mergeable` state
  (`MERGEABLE`/`CONFLICTING`/`UNKNOWN`/`BEHIND`). A transition into
  `CONFLICTING` is called out explicitly — the script does **not** attempt to
  resolve it. Conflict resolution needs a judgment call about which side's
  change is correct; a script guessing is how you silently lose someone's
  work.
- Reports every transition of one or more named checks you tell it to watch
  (defaults to `"E2E Tests (Chromium)"` — override with `--watch-check` for
  your own CI's job name).
- When a watched check fails, looks at that run's own log/annotations for a
  cancellation marker (`canceling|cancelled` by default, override with
  `--cancel-pattern`). If found, reruns the failed jobs and keeps polling. If
  not found, reports it as a genuine failure and stops auto-handling — it
  still keeps watching mergeable/merged state, it just won't blindly rerun a
  real failure forever.

## Usage

```bash
./pr-merge-watcher.sh [options] PR_NUMBER [PR_NUMBER ...]
```

```
Options:
  --repo OWNER/NAME       Target repo (defaults to gh's current repo context)
  --watch-check NAME      Check name to watch for cancel/rerun (repeatable;
                          default: "E2E Tests (Chromium)")
  --cancel-pattern REGEX  Case-insensitive grep pattern identifying a
                          cancellation in `gh run view`'s output
                          (default: "canceling|cancelled")
  --poll-interval SECS    Seconds between polls (default: 25)
  --timeout SECS          Give up after this many seconds (default: 1800)
```

Example, run from inside the target repo:

```bash
./pr-merge-watcher.sh --watch-check "E2E Tests (Chromium)" 247 253 257 258
```

Watching two different concurrency-bound jobs in someone else's repo:

```bash
./pr-merge-watcher.sh --repo myorg/myrepo \
  --watch-check "E2E Tests" --watch-check "Integration Tests" \
  --cancel-pattern "canceled|superseded" \
  101 102 103
```

Exit code is `0` if every PR reached `MERGED` before the timeout, `1`
otherwise (including on timeout, printing which PRs are still unmerged).

## Requirements

- [`gh`](https://cli.github.com/) (authenticated, with access to the target
  repo)
- `jq`

## What it deliberately doesn't do

- **It doesn't resolve merge conflicts.** When it reports `REAL CONFLICT`,
  that's a stop sign for a human (or an agent with actual repo access and the
  judgment to pick the right resolution), not a queue for the script.
- **It doesn't retry a check indefinitely.** A genuine failure is reported
  once per state transition and left alone — it won't rerun a job whose
  cancellation marker it didn't find, because that would just as happily mask
  a real, reproducible failure as a real cancellation.
- **It's not a merge queue.** GitHub's own merge queue feature solves this
  problem more robustly if you can enable it on your repo. This script exists
  for the case where you can't (e.g. you don't have admin rights to turn it
  on, or you're coordinating across repos that don't have it) and need
  visibility into what auto-merge is silently stuck on.

## License

MIT — see [LICENSE](LICENSE).

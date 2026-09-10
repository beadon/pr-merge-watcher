#!/usr/bin/env bash
#
# pr-merge-watcher.sh — watch a set of GitHub PRs through CI and merge.
#
# Built out of a real problem: running many auto-merge-enabled PRs against a
# fast-moving base branch (several tickets landing per hour, from one agent
# or several working in parallel). Two failure modes showed up immediately:
#
#   1. A CI job that needs exclusive infrastructure (e.g. E2E tests bound to
#      fixed ports) uses a concurrency group with `cancel-in-progress: true`.
#      When N PRs push near-simultaneously, GitHub cancels all but the latest
#      run in that group — every PR but one comes back "failed", but it's a
#      cancellation, not a real test failure. Silently retrying is correct
#      here; treating it as a real failure and giving up is not.
#
#   2. A real merge conflict, or a duplicate Alembic-style migration revision
#      ID, blocks the merge outright. auto-merge (`gh pr merge --auto`)
#      degrades this to "just sits there" — GitHub does not surface it loudly,
#      and a coordinator polling only `gh pr view --json state` never learns
#      why nothing is progressing. This needs a human (or an agent with write
#      access to the branch) to actually resolve it — the script must say so
#      distinctly from "still running."
#
# This script polls a list of PR numbers and, for each one:
#   - reports MERGED once GitHub says so, then stops watching it
#   - reports every mergeable-state transition (MERGEABLE/CONFLICTING/BEHIND/UNKNOWN)
#   - reports every named check's pass/fail transition
#   - when a named check fails AND the run log contains a cancellation marker
#     (customize via --cancel-pattern for your CI's own wording), reruns it
#     automatically and keeps waiting
#   - when a named check fails and is NOT a detected cancellation, reports it
#     as a real failure and stops auto-handling that PR (still keeps watching
#     its mergeable/merged state)
#   - when a PR's mergeable state is CONFLICTING, reports it distinctly and
#     does NOT attempt to auto-resolve it — conflict resolution needs
#     judgment about which side's changes to keep, not a script guessing
#
# Requires: `gh` (authenticated), `jq`.
#
# Usage:
#   ./pr-merge-watcher.sh [options] PR_NUMBER [PR_NUMBER ...]
#
# Options:
#   --repo OWNER/NAME       Target repo (defaults to gh's current repo context)
#   --watch-check NAME      Check name to watch for cancel/rerun (repeatable;
#                           default: "E2E Tests (Chromium)" — override for
#                           your own CI's concurrency-bound job name(s))
#   --cancel-pattern REGEX  Case-insensitive grep pattern identifying a
#                           cancellation in `gh run view`'s annotation output
#                           (default: "canceling|cancelled")
#   --poll-interval SECS    Seconds between polls (default: 25)
#   --timeout SECS          Give up after this many seconds (default: 1800)
#
# Exit code: 0 if every PR reached MERGED before timeout, 1 otherwise.
#
# Example:
#   ./pr-merge-watcher.sh --repo myorg/myrepo --watch-check "E2E Tests (Chromium)" \
#     247 253 257 258
#
set -uo pipefail

REPO=""
WATCH_CHECKS=()
CANCEL_PATTERN="canceling|cancelled"
POLL_INTERVAL=25
TIMEOUT=1800
PRS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --watch-check) WATCH_CHECKS+=("$2"); shift 2 ;;
    --cancel-pattern) CANCEL_PATTERN="$2"; shift 2 ;;
    --poll-interval) POLL_INTERVAL="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^#//'; exit 0 ;;
    *) PRS+=("$1"); shift ;;
  esac
done

if [ ${#PRS[@]} -eq 0 ]; then
  echo "Usage: $0 [options] PR_NUMBER [PR_NUMBER ...]" >&2
  exit 2
fi

if [ ${#WATCH_CHECKS[@]} -eq 0 ]; then
  WATCH_CHECKS=("E2E Tests (Chromium)")
fi

REPO_ARGS=()
if [ -n "$REPO" ]; then
  REPO_ARGS=(--repo "$REPO")
fi

declare -A merged
declare -A last_mergeable
declare -A last_check_state

start_ts=$(date +%s)

log() { echo "[$(date +%H:%M:%S)] $*"; }

check_one_pr() {
  local pr="$1"
  local info state mergeable
  info=$(gh pr view "$pr" "${REPO_ARGS[@]}" --json state,mergeable,mergeStateStatus 2>/dev/null) || return
  state=$(jq -r .state <<<"$info")
  mergeable=$(jq -r .mergeable <<<"$info")

  if [ "$state" = "MERGED" ]; then
    if [ -z "${merged[$pr]:-}" ]; then
      log "PR #$pr: MERGED"
      merged[$pr]=1
    fi
    return
  fi

  if [ "$mergeable" != "${last_mergeable[$pr]:-}" ]; then
    log "PR #$pr mergeable: $mergeable"
    last_mergeable[$pr]=$mergeable
    if [ "$mergeable" = "CONFLICTING" ]; then
      log "PR #$pr: REAL CONFLICT — needs manual resolution, not auto-handled"
    fi
  fi

  local checks_json
  checks_json=$(gh pr checks "$pr" "${REPO_ARGS[@]}" --json name,state,link 2>/dev/null) || return

  for check_name in "${WATCH_CHECKS[@]}"; do
    local key="${pr}::${check_name}"
    local check_state
    check_state=$(jq -r --arg n "$check_name" '.[] | select(.name==$n) | .state' <<<"$checks_json" | head -1)
    [ -z "$check_state" ] && continue

    if [ "$check_state" != "${last_check_state[$key]:-}" ]; then
      log "PR #$pr check '$check_name': $check_state"
      last_check_state[$key]=$check_state
    fi

    if [ "$check_state" = "FAILURE" ] && [ "$mergeable" != "CONFLICTING" ]; then
      local run_id
      run_id=$(jq -r --arg n "$check_name" '.[] | select(.name==$n) | .link' <<<"$checks_json" \
        | grep -oP 'runs/\K[0-9]+' | head -1)
      [ -z "$run_id" ] && continue

      if gh run view "$run_id" "${REPO_ARGS[@]}" 2>/dev/null | grep -qiE "$CANCEL_PATTERN"; then
        log "PR #$pr: '$check_name' was cancelled (concurrency lock) — rerunning"
        gh run rerun "$run_id" "${REPO_ARGS[@]}" --failed >/dev/null 2>&1
        # Give GitHub a moment to register the rerun before the next poll,
        # so we don't immediately re-read the stale FAILURE state and loop.
        sleep 10
      else
        log "PR #$pr: '$check_name' genuinely failed — needs investigation"
      fi
    fi
  done
}

log "Watching PRs: ${PRS[*]} (checks: ${WATCH_CHECKS[*]})"

while true; do
  all_done=1
  for pr in "${PRS[@]}"; do
    [ -n "${merged[$pr]:-}" ] && continue
    all_done=0
    check_one_pr "$pr"
  done

  if [ "$all_done" = "1" ]; then
    log "ALL_MERGED"
    exit 0
  fi

  now=$(date +%s)
  if [ $(( now - start_ts )) -ge "$TIMEOUT" ]; then
    log "TIMEOUT after ${TIMEOUT}s — unmerged: $(for pr in "${PRS[@]}"; do [ -z "${merged[$pr]:-}" ] && printf '#%s ' "$pr"; done)"
    exit 1
  fi

  sleep "$POLL_INTERVAL"
done

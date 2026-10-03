#!/usr/bin/env bash
#
# update-stale-branches.sh — bring BEHIND PRs up to date with their base, one pass.
#
# Copyright (C) 2026 beadon
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Built to cover the gap a GitHub merge queue would otherwise close, for
# orgs/repos where merge queue isn't available (it is plan/feature gated and
# may simply not be offered, even on a plan that's supposed to support it —
# check your repo's Settings > Rules > New branch ruleset for a "merge
# queue" rule before assuming this script is the only option).
#
# Branch protection with strict status checks requires a PR be "up to date"
# with its base before it can merge, but nothing re-triggers that update
# automatically when the base branch moves. Under high PR velocity (several
# tickets landing per hour, from one agent or several working in parallel)
# this leaves PRs stuck BEHIND indefinitely unless someone manually calls
# the update-branch API.
#
# This is deliberately a single pass, not a watcher or a background job: run
# it when you notice PRs piling up BEHIND, not on an automatic trigger. An
# auto-update-on-every-push workflow sounds like the obvious next step but
# isn't — it re-triggers CI for PRs that aren't ready to merge yet, which is
# exactly the CI-thrash problem this is meant to reduce, not add to.
#
# It does not touch CONFLICTING PRs — those need human judgment about which
# side's changes to keep, same boundary as pr-merge-watcher.sh.
#
# Requires: `gh` (authenticated), `jq`.
#
# Usage:
#   ./update-stale-branches.sh [options] [PR_NUMBER ...]
#
# Options:
#   --repo OWNER/NAME   Target repo (defaults to gh's current repo context)
#   --base BRANCH       Only consider open PRs targeting this base when no
#                        PR_NUMBER args are given (default: repo's default branch)
#   --dry-run           Report what would be updated, don't call the API
#
# With no PR_NUMBER args, discovers every open PR targeting --base and
# checks each one's mergeStateStatus, calling update-branch only on the ones
# reported BEHIND.
#
# Exit code: 0 if every BEHIND PR was successfully queued for update, 1 if
# any update-branch call failed. CONFLICTING PRs are reported but don't
# affect the exit code — resolving them isn't this script's job.
#
# Example:
#   ./update-stale-branches.sh --repo myorg/myrepo --base development
#   ./update-stale-branches.sh --repo myorg/myrepo 737 740 744 745 746
#
set -uo pipefail

REPO=""
BASE=""
DRY_RUN=0
PRS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^#//'; exit 0 ;;
    *) PRS+=("$1"); shift ;;
  esac
done

REPO_ARGS=()
if [ -n "$REPO" ]; then
  REPO_ARGS=(--repo "$REPO")
fi

log() { echo "[$(date +%H:%M:%S)] $*"; }

if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || {
    echo "Could not resolve target repo — pass --repo owner/name" >&2
    exit 2
  }
fi

if [ ${#PRS[@]} -eq 0 ]; then
  if [ -z "$BASE" ]; then
    BASE=$(gh repo view "${REPO_ARGS[@]}" --json defaultBranchRef -q .defaultBranchRef.name)
  fi
  log "No PR numbers given — discovering open PRs targeting '$BASE'"
  mapfile -t PRS < <(gh pr list "${REPO_ARGS[@]}" --base "$BASE" --state open --json number -q '.[].number')
fi

if [ ${#PRS[@]} -eq 0 ]; then
  log "No open PRs found to check."
  exit 0
fi

fail=0

for pr in "${PRS[@]}"; do
  info=$(gh pr view "$pr" "${REPO_ARGS[@]}" --json mergeStateStatus,headRefName 2>/dev/null) || {
    log "PR #$pr: could not fetch (skipping)"
    continue
  }
  status=$(jq -r .mergeStateStatus <<<"$info")
  branch=$(jq -r .headRefName <<<"$info")

  case "$status" in
    BEHIND)
      if [ "$DRY_RUN" = "1" ]; then
        log "PR #$pr ($branch): BEHIND — would update-branch (dry run)"
        continue
      fi
      log "PR #$pr ($branch): BEHIND — updating"
      if gh api -X PUT "repos/$REPO/pulls/$pr/update-branch" >/dev/null 2>&1; then
        log "PR #$pr: update-branch queued"
      else
        log "PR #$pr: update-branch call FAILED"
        fail=1
      fi
      ;;
    CONFLICTING)
      log "PR #$pr ($branch): CONFLICTING — not touching, needs manual resolution"
      ;;
    *)
      log "PR #$pr ($branch): $status — nothing to do"
      ;;
  esac
done

exit $fail

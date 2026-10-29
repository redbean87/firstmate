#!/usr/bin/env bash
# Live driver: drive the shipped shared GitHub check verdict
# (bin/fm-pr-github-checks-lib.sh) exactly as a readiness caller would - no
# waivers - against real, read-only GitHub answers for a public repository.
# Nothing is written to GitHub; every call is a read.
#
# Usage: readiness-live-github.sh <worktree> <repo-slug> <green-pr> <red-pr> <out>
set -u

WT=$1
REPO=$2
GREEN_PR=$3
RED_PR=$4
OUT=$5

owner=${REPO%%/*}
repo=${REPO##*/}
export GH_HOST=github.com

cursor() {  # <pr-number> -> live payload on stdout
  gh pr view "$1" --repo "$REPO" \
    --json state,isDraft,mergeStateStatus,headRefOid,baseRefName,statusCheckRollup
}

# Call the verdict the way a readiness path would: no waiver arguments.
verdict() {  # <label> <payload> <base> <head> [extra verdict args...]
  local label=$1 payload=$2 base=$3 head=$4
  shift 4
  (
    cd "$WT" || exit 1
    # shellcheck source=/dev/null
    . ./bin/fm-pr-github-checks-lib.sh
    PR_OWNER=$owner
    PR_REPO=$repo
    rc=0
    fm_pr_github_check_verdict "$payload" "$base" "$head" "$@" || rc=$?
    printf 'rc=%s\n' "$rc"
    printf 'status=%s\n' "$FM_PR_GITHUB_VERDICT_STATUS"
    printf 'incomplete=%s\n' "$FM_PR_GITHUB_VERDICT_INCOMPLETE"
    printf 'red=[%s]\n' "$FM_PR_GITHUB_VERDICT_RED_LIST"
    printf 'unreported=[%s]\n' "$FM_PR_GITHUB_VERDICT_UNREPORTED_LIST"
    printf 'lines:\n%s' "$FM_PR_GITHUB_VERDICT_LINES"
  ) > "/tmp/fm-verdict-$$.out" 2> "/tmp/fm-verdict-$$.err"
  printf '\n===== %s =====\n' "$label"
  cat "/tmp/fm-verdict-$$.out"
  printf 'stderr:\n'
  cat "/tmp/fm-verdict-$$.err"
  rm -f "/tmp/fm-verdict-$$.out" "/tmp/fm-verdict-$$.err"
}

{
  printf 'repository: %s (public, read-only)\n' "$REPO"
  printf 'predicate: %s/bin/fm-pr-github-checks-lib.sh via source, real gh + jq\n' "$WT"
  printf 'run started: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'gh login: %s\n' "$(gh api user --jq .login)"

  green_payload=$(cursor "$GREEN_PR")
  green_head=$(printf '%s' "$green_payload" | jq -r .headRefOid)
  green_base=$(printf '%s' "$green_payload" | jq -r .baseRefName)
  printf '\nPR %s head=%s base=%s\n' "$GREEN_PR" "$green_head" "$green_base"
  printf 'GitHub its own verdict for PR %s: mergeStateStatus=%s, %s checks in the rollup\n' \
    "$GREEN_PR" "$(printf '%s' "$green_payload" | jq -r .mergeStateStatus)" \
    "$(printf '%s' "$green_payload" | jq -r '.statusCheckRollup | length')"
  verdict "R1. real green PR $GREEN_PR with no waivers is green" \
    "$green_payload" "$green_base" "$green_head"

  red_payload=$(cursor "$RED_PR")
  red_head=$(printf '%s' "$red_payload" | jq -r .headRefOid)
  red_base=$(printf '%s' "$red_payload" | jq -r .baseRefName)
  printf '\nPR %s head=%s base=%s\n' "$RED_PR" "$red_head" "$red_base"
  printf 'GitHub its own verdict for PR %s: mergeStateStatus=%s, %s checks in the rollup\n' \
    "$RED_PR" "$(printf '%s' "$red_payload" | jq -r .mergeStateStatus)" \
    "$(printf '%s' "$red_payload" | jq -r '.statusCheckRollup | length')"
  verdict "R2. real red PR $RED_PR with no waivers is blocked and names the red check" \
    "$red_payload" "$red_base" "$red_head"

  verdict "R3. the same green payload against a base branch GitHub cannot read is never green" \
    "$green_payload" "fm-no-such-base-branch" "$green_head"

  verdict "R4. the same green payload at a different head is never green" \
    "$green_payload" "$green_base" "0000000000000000000000000000000000000000"

  verdict "R5. a red check waived is the attended gate verdict, not readiness" \
    "$red_payload" "$red_base" "$red_head" --allow-red "$(printf '%s' "$red_payload" | jq -r '.statusCheckRollup[0].name')"

  printf '\n===== R6. sourcing the shared library is silent (no poll output, no wake) =====\n'
  printf 'stdout+stderr bytes: '
  ( cd "$WT" && . ./bin/fm-pr-github-checks-lib.sh ) 2>&1 | wc -c
  printf 'functions exposed: '
  ( cd "$WT" && . ./bin/fm-pr-github-checks-lib.sh && type -t fm_pr_github_check_verdict )
} 2>&1 | tee "$OUT"

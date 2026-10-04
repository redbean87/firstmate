#!/usr/bin/env bash
# Execute ci.yml's detect-changes "scope" step exactly as GitHub Actions would:
# the run block is extracted from the workflow YAML by its step id (typed parse,
# not string matching), the four ${{ ... }} expressions are substituted with the
# event values of the simulated pull_request payload, and the block runs under
# bash with set -eu and a real GITHUB_OUTPUT file.
#
# Usage: drive-scope-step.sh <event-name> <base-sha> <head-sha>
set -u

REPO="${FM_TEST_REPO:-$PWD}"
WF="$REPO/.github/workflows/ci.yml"
event="${1:?event required}"; base="${2:?base required}"; head="${3:?head required}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-scope.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT

ruby -ryaml -e '
doc = YAML.load_file(ARGV[0])
step = doc.fetch("jobs").fetch("detect-changes").fetch("steps").find { |s| s["id"] == "scope" }
raise "no scope step in detect-changes" unless step
print step.fetch("run")
' "$WF" > "$tmp/scope.sh" || { echo "extraction failed"; exit 1; }

# Substitute the workflow-context expressions GitHub expands before the shell sees.
sed -e "s|\${{ github.event.pull_request.base.sha }}|$base|g" \
    -e "s|\${{ github.event.before }}|$base|g" \
    -e "s|\${{ github.sha }}|$head|g" \
    -e "s|\${{ github.event_name }}|$event|g" \
    "$tmp/scope.sh" > "$tmp/scope-expanded.sh"

if grep -q '\${{' "$tmp/scope-expanded.sh"; then
  echo "unsubstituted expression remains:"; grep -n '\${{' "$tmp/scope-expanded.sh"; exit 1
fi

: > "$tmp/github_output"
( cd "$REPO" && GITHUB_OUTPUT="$tmp/github_output" bash "$tmp/scope-expanded.sh" )
rc=$?
echo "--- scope step exit=$rc"
echo "--- GITHUB_OUTPUT:"
cat "$tmp/github_output"

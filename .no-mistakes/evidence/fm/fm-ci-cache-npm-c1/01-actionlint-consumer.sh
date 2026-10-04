#!/usr/bin/env bash
# Scenario 1: the changed ci.yml is accepted by the repo's real workflow
# consumer (pinned actionlint via bin/fm-lint-workflows.sh), and a negative
# control proves that consumer actually validates the NEW cache-step
# expressions (a broken steps.<id>.outputs reference must fail).
set -eu
ROOT="${1:?usage: 01-actionlint-consumer.sh <repo-root>}"
cd "$ROOT"

ALBIN=$(mktemp -d "${TMPDIR:-/tmp}/fm-al.XXXXXX")
trap 'rm -rf "$ALBIN"' EXIT
bin/fm-install-actionlint.sh "$ALBIN" >/dev/null
export PATH="$ALBIN:$PATH"

echo "== positive: lint all workflows with pinned actionlint =="
bin/fm-lint-workflows.sh

echo
echo "== negative control: break a cache-step expression in a COPY and re-lint =="
COPYDIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-al-copy.XXXXXX")
trap 'rm -rf "$ALBIN" "$COPYDIR"' EXIT
mkdir -p "$COPYDIR/.github/workflows"
cp .github/workflows/*.yml "$COPYDIR/.github/workflows/"
# Point the cache key at a step id that does not exist.
ruby -pi -e 'gsub("steps.npm-cache-node.outputs.major", "steps.npm-cache-typo.outputs.major")' \
  "$COPYDIR/.github/workflows/ci.yml"
set +e
bin/fm-lint-workflows.sh --root "$COPYDIR" 2>&1
rc=$?
set -e
echo "negative-control exit code: $rc (non-zero expected)"
if [ "$rc" -eq 0 ]; then
  echo "FAIL: actionlint accepted a broken cache-step expression"
  exit 1
fi
echo "OK: actionlint rejects the broken cache-step expression, so the positive result is meaningful"

#!/usr/bin/env bash
# fm-test-shard-tripwire.sh - annotate a CI test shard log whose run was cut
# off before it reached FM_TEST_SUMMARY.
#
# Usage: fm-test-shard-tripwire.sh <shard-log>
#
# A shard that rides into its job's hang tripwire is killed mid-script: the log
# ends with an FM_TEST_BEGIN that never got its FM_TEST_END, no timing artifact
# is finalized, and the cancelled check reads like flakiness. This script reads
# the teed shard log and, when the run never reached FM_TEST_SUMMARY, appends
# one section to $GITHUB_STEP_SUMMARY (and prints it) naming the script that
# was running, its last FM_TEST_BEGIN line, and its modeled weight (the
# weight_ms the runner stamped on that marker) against the actual runtime it
# had accumulated when the shard was cut off. It also emits one ::warning::
# line so the same fact surfaces as a run annotation.
#
# Design note: the annotation lives in a separate if: always() step reading the
# teed log, not in a signal trap. A job-cap kill SIGKILLs the runner and any
# wrapper around it, so only a step that survives the kill can annotate.
#
# A complete run (the log carries FM_TEST_SUMMARY) is annotated with nothing,
# and so is a missing log: nothing to report is not an error.
#
# Exit status: 0 on a complete run, a missing log, or an unparseable marker;
# 2 on usage errors. This step must never decide the shard's verdict.
set -eu

die() {
  printf 'fm-test-shard-tripwire: %s\n' "$*" >&2
  exit 2
}

# The runner stamps UTC ISO-8601 on its markers. Convert it portably: BSD date
# parses with -j -f, GNU date with -d.
iso_to_epoch() {
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-5][0-9]Z) ;;
    *) return 1 ;;
  esac
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null \
    || date -u -d "$1" +%s 2>/dev/null \
    || return 1
}

# Append <markdown-or-text> to the step summary when GitHub provides one, and
# always print it so the fact also lands in this step's log.
emit() {
  printf '%s\n' "$1"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$1" >>"$GITHUB_STEP_SUMMARY"
  fi
}

[ "$#" -eq 1 ] || die "usage: fm-test-shard-tripwire.sh <shard-log>"
LOG=$1

# A log that was never written means the shard died before it produced output;
# there is no script to name and no marker to quote.
[ -f "$LOG" ] || exit 0

# A completed run accounts for every script in its own summary; the ordinary
# verdict (pass or fail) already carries the signal, so there is nothing to add.
if grep -q '^FM_TEST_SUMMARY ' "$LOG"; then
  exit 0
fi

last_begin=$(grep '^FM_TEST_BEGIN ' "$LOG" | tail -n 1 || true)

if [ -z "$last_begin" ]; then
  emit '### Shard cut off before any script began'
  emit ''
  # shellcheck disable=SC2016 # Literal markdown backticks, not shell expansion.
  emit 'This shard log never recorded an `FM_TEST_BEGIN`, so it was cut off during setup before any test script started.'
  printf '::warning::shard log cut off before any test script began\n'
  exit 0
fi

begin_iso=$(printf '%s\n' "$last_begin" | awk '{print $2}')
script=$(printf '%s\n' "$last_begin" | awk '{print $3}')
family=$(printf '%s\n' "$last_begin" | sed -n 's/.* family=\([^ ]*\).*/\1/p')
weight_ms=$(printf '%s\n' "$last_begin" | sed -n 's/.* weight_ms=\([0-9][0-9]*\).*/\1/p')

actual_secs=
if begin_epoch=$(iso_to_epoch "$begin_iso"); then
  actual_secs=$(( $(date +%s) - begin_epoch ))
  [ "$actual_secs" -ge 0 ] || actual_secs=0
fi

modeled_line='- Modeled runtime: unknown (the FM_TEST_BEGIN marker carried no weight_ms)'
if [ -n "$weight_ms" ]; then
  modeled_line="- Modeled runtime: ${weight_ms} ms; actual runtime at cutoff: ${actual_secs:-unknown} s"
fi

emit '### Shard cut off before its summary'
emit ''
# shellcheck disable=SC2016 # Literal markdown backticks, not shell expansion.
emit 'This shard log ended without `FM_TEST_SUMMARY`: it was cut off mid-run, so no test verdict was recorded for it. A cancelled check here is this tripwire firing, not a flaky test.'
emit ''
emit "- Running script: \`${script}\` (family=${family:-unknown})"
emit "- Last \`FM_TEST_BEGIN\`: \`${last_begin}\`"
emit "$modeled_line"

printf '::warning::shard cut off mid-script: %s was running (modeled %s ms, actual %s s at cutoff)\n' \
  "$script" "${weight_ms:-unknown}" "${actual_secs:-unknown}"

exit 0

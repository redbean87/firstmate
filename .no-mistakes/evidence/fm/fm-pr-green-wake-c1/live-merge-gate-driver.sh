#!/usr/bin/env bash
# Live driver: drive the real bin/fm-pr-merge.sh in a disposable lab home with a
# fake gh that stands in for GitHub's HTTP API, and print one transcript block
# per scenario. Everything disposable lives under $LAB and is removed on exit.
set -u

WT=$1                       # the gate worktree (real product source)
OUT=$2                      # transcript destination
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || exit 1
cleanup() { rm -rf "$LAB"; }
trap cleanup EXIT

mkdir -p "$LAB/config" "$LAB/state" "$LAB/data" "$LAB/projects" "$LAB/fakebin"
printf '{"protected":false}\n' >/dev/null
printf 'lab home: %s\n' "$LAB"

HEAD=11e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1
BASE=main
URL=https://github.com/example/repo/pull/11

# --- fixture: one task, one worktree ---------------------------------------
mkdir -p "$LAB/wt"
git -C "$LAB/wt" init -q
git -C "$LAB/wt" config user.email fmtest@example.invalid
git -C "$LAB/wt" config user.name fmtest
git -C "$LAB/wt" commit -q --allow-empty -m fixture
git -C "$LAB/wt" update-ref refs/remotes/origin/main "$(git -C "$LAB/wt" rev-parse HEAD)"
printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
cat > "$LAB/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
TOML
cat > "$LAB/state/task-x1.meta" <<META
window=fm-task-x1
worktree=$LAB/wt
project=$LAB/project
kind=ship
mode=no-mistakes
META

# --- the fake forge --------------------------------------------------------
# $FIXDIR holds one answer per read the real scripts make. A marker file makes a
# read fail, so a scenario can drive a real read error.
FIXDIR=$LAB/fix
mkdir -p "$FIXDIR"
cat > "$LAB/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -u
fix=${FM_FAKE_GH_FIX:?}
printf '%s\n' "$*" >> "$fix/gh.log"
case "${1:-} ${2:-}" in
  "pr view")
    [ ! -e "$fix/view-fail" ] || { echo 'error: could not read pr' >&2; exit 1; }
    cat "$fix/view.json"
    ;;
  "pr merge")
    printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}"
    ;;
  "api graphql")
    [ ! -e "$fix/graphql-fail" ] || { echo 'error: could not reach the GitHub API' >&2; exit 1; }
    cat "$fix/outcome.fields"
    ;;
  api\ *)
    case " $* " in
      *"/commits/"*"/check-runs"*)
        [ ! -e "$fix/runs-fail" ] || exit 1
        cat "$fix/runs.json"
        ;;
      *"/rules/branches/"*)
        if [ -e "$fix/rules-fail-body" ]; then
          cat "$fix/rules-fail-body" >&2
          exit 1
        fi
        [ ! -e "$fix/rules-fail" ] || exit 1
        cat "$fix/rules.json"
        ;;
      *"/branches/"*)
        [ ! -e "$fix/branch-fail" ] || { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
        cat "$fix/branch.json"
        ;;
      *)
        echo "fake gh: unexpected api call: $*" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "fake gh: unexpected call: $*" >&2
    exit 1
    ;;
esac
SH
cat > "$LAB/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
set -u
fix=${FM_FAKE_GH_FIX:?}
printf 'axi %s\n' "$*" >> "$fix/gh.log"
case "${1:-} ${2:-}" in
  "pr view") printf 'pull_request:\n  number: %s\n  state: merged\n' "${3:-}" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$LAB/fakebin/gh" "$LAB/fakebin/gh-axi"

# --- fixture answers -------------------------------------------------------
# $1 = rollup entry JSON list, $2 = classic required name (or empty),
# $3 = ruleset required name (or empty)
write_fixture() {
  local rollup=$1 classic=${2:-} ruleset=${3:-} contexts='' checks='' rules='' protected=false
  rm -f "$FIXDIR"/*-fail "$FIXDIR"/rules-fail-body "$FIXDIR"/gh.log
  if [ -n "$classic" ]; then
    protected=true
    contexts="\"$classic\""
    checks="{\"context\":\"$classic\",\"app_id\":null}"
  fi
  [ -z "$ruleset" ] || rules="{\"type\":\"required_status_checks\",\"parameters\":{\"required_status_checks\":[{\"context\":\"$ruleset\"}]}}"
  printf '{"name":"main","protected":%s,"protection":{"enabled":%s,"required_status_checks":{"enforcement_level":"%s","contexts":[%s],"checks":[%s]}}}\n' \
    "$protected" "$protected" "$([ "$protected" = true ] && echo non_admins || echo off)" "$contexts" "$checks" \
    > "$FIXDIR/branch.json"
  printf '[{"type":"deletion"}%s]\n' "${rules:+,$rules}" > "$FIXDIR/rules.json"
  printf '{"check_runs":[]}\n' > "$FIXDIR/runs.json"
  printf '%s\n' 'state=MERGED' 'merged=true' 'queued=false' 'base=main' > "$FIXDIR/outcome.fields"
  printf '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"%s","baseRefName":"main","statusCheckRollup":[%s]}\n' \
    "$HEAD" "$rollup" > "$FIXDIR/view.json"
}

run_merge() {  # <label> [args...]
  local label=$1
  shift
  : > "$FIXDIR/gh.log"
  set +e
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
      -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
      FM_HOME="$LAB" HOME="$LAB/user-home" FM_FAKE_GH_FIX="$FIXDIR" \
      PATH="$LAB/fakebin:$PATH" \
      "$WT/bin/fm-pr-merge.sh" task-x1 "$URL" "$@" > "$FIXDIR/stdout" 2> "$FIXDIR/stderr"
  RC=$?
  set -e
  printf '\n===== %s =====\n' "$label"
  printf 'exit=%s\n' "$RC"
  printf -- '-- stderr --\n'
  cat "$FIXDIR/stderr"
  printf -- '-- stdout --\n'
  cat "$FIXDIR/stdout"
  printf -- '-- every fake-gh call --\n'
  sed 's/^/  /' "$FIXDIR/gh.log" || true
}

CHECK_GREEN='{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}'
CHECK_RED='{"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"FAILURE"}'

set -e
{
  printf 'real script: %s/bin/fm-pr-merge.sh\n' "$WT"

  write_fixture "$CHECK_GREEN" ci
  run_merge "A. green required check at the live head merges with zero waivers"

  write_fixture "$CHECK_RED"
  run_merge "B. red check refuses and nothing merges"

  write_fixture "$CHECK_GREEN" deploy
  run_merge "C. required check that never reported refuses, named apart from red"

  write_fixture "$CHECK_GREEN" deploy
  : > "$FIXDIR/branch-fail"
  run_merge "D. unreadable required-context source refuses instead of reading as green"

  write_fixture "$CHECK_RED"
  run_merge "E. attended --allow-red still waives only its named check" --attended-override --allow-red lint

  write_fixture "$CHECK_GREEN" deploy
  run_merge "F. attended --allow-missing waives only its named unreported check" --attended-override --allow-missing deploy

  write_fixture "$CHECK_GREEN"
  printf '{"state":"OPEN","headRefOid":"%s","baseRefName":"main"}\n' "$HEAD" > "$FIXDIR/view.json"
  run_merge "G. a payload with no check rollup is refused, never read as green"

  write_fixture "$CHECK_GREEN"
  printf '%s\n' 'gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)' > "$FIXDIR/rules-fail-body"
  run_merge "H. plan-gated rules read still proves no ruleset requirement and merges"
} 2>&1 | tee "$OUT"

# A Gerrit change must stay refused: this slice introduces no Gerrit readiness.
printf '\n===== I. Gerrit change stays refused =====\n' | tee -a "$OUT"
set +e
"$WT/bin/fm-pr-merge.sh" task-x1 https://gerrit.example/c/project/+/42 > "$LAB/gerrit.out" 2> "$LAB/gerrit.err"
GERRIT_RC=$?
set -e
printf 'exit=%s\n' "$GERRIT_RC" | tee -a "$OUT"
cat "$LAB/gerrit.err" | tee -a "$OUT"

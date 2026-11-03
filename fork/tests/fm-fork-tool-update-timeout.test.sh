#!/usr/bin/env bash
# HK9's behaviour: the watched tool-update sweep treats what the clock - never
# an answer - produced as unverified, and bounds every tool's share of the
# sweep budget.
#
# The incident this pins: a link that answers git in 7-10 seconds against the
# default 5s probe bound made every 15-minute poll report
# "<repo> check failed: origin did not answer where main points" plus
# "check incomplete: the time budget ran out before <tool>", with no tool out
# of date. A latency-only sweep must now produce no wake at all, one slow
# remote must not spend the sweep budget of the tools after it, and every
# finding a probe actually answered - a stale clone, a genuine remote error, a
# local probe that ran and stalled - must keep reporting exactly as upstream
# wrote it.
#
# No case reaches the network: a fake git answers the remote probes by repo
# path and hands everything else to the real git, and every watched repository
# is a local fixture clone.
set -u

# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-tool-update-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-fork-tool-update-timeout)

# A host with no git identity would fail the fixture commits, leaving each
# case in a shape it did not ask for.
fm_git_identity fmtest fmtest@example.invalid

make_home() {  # <name>: a fixture home with empty state and config dirs
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  printf '%s\n' "$home"
}

write_config() {
  local home=$1
  shift
  printf '%s\n' "$*" > "$home/config/watched-tools.json"
}

# Ambient PATH behind the fake, which the check needs for jq, date, grep, and
# the rest; every watched repository is under TMP_ROOT, which carries neither
# "slow" nor "broken", so the fake's path matching only reads its own fixtures.
fixture_path() {
  printf '%s:%s\n' "$1" "$PATH"
}

# make_remote_fake_git <dir>: a git whose ls-remote never answers for a
# repository whose path contains "slow" (the latency fixture), answers with a
# genuine fatal status 128 for one containing "broken", and execs the real git
# for everything else - so the local probes stay fast and truthful while only
# the network probe is delayed or broken.
make_remote_fake_git() {
  local dir=$1 real
  real=$(command -v git)
  mkdir -p "$dir"
  cat > "$dir/git" <<SH
#!/usr/bin/env bash
real='$real'
repo=
prev=
for arg in "\$@"; do
  [ "\$prev" = "-C" ] && repo=\$arg
  prev=\$arg
done
is_ls_remote=0
for arg in "\$@"; do
  [ "\$arg" = "ls-remote" ] && is_ls_remote=1
done
if [ "\$is_ls_remote" -eq 1 ]; then
  case " \$repo " in
    *slow*) sleep 30; exit 0 ;;
    *broken*) printf 'fatal: could not read from remote\n' >&2; exit 128 ;;
  esac
fi
exec "\$real" "\$@"
SH
  chmod 0755 "$dir/git"
}

# make_stalled_local_git <dir>: a git whose local rev-parse never answers -
# the upstream-pinned case of a local probe that runs and stalls, which stays a
# check failure whatever the clock does.
make_stalled_local_git() {
  local dir=$1 real
  real=$(command -v git)
  mkdir -p "$dir"
  cat > "$dir/git" <<SH
#!/usr/bin/env bash
real='$real'
for arg in "\$@"; do
  if [ "\$arg" = "rev-parse" ]; then
    sleep 30
    exit 0
  fi
done
exec "\$real" "\$@"
SH
  chmod 0755 "$dir/git"
}

# git_fixture <name>: a local clone whose origin branch is three commits ahead
# with those commits present locally, so an untouched clone is current. The
# fixture directory name carries <name>, which is how the fake git picks its
# behaviour for that repository.
git_fixture() {
  local name=$1 bare work
  bare="$TMP_ROOT/$name.git"
  work="$TMP_ROOT/$name"
  git init -q --bare --initial-branch=main "$bare"
  git clone -q "$bare" "$work" 2>/dev/null
  printf 'one\n' > "$work/f1"
  git -C "$work" add f1
  git -C "$work" commit -qm one
  printf 'two\n' > "$work/f2"
  git -C "$work" add f2
  git -C "$work" commit -qm two
  printf 'three\n' > "$work/f3"
  git -C "$work" add f3
  git -C "$work" commit -qm three
  git -C "$work" push -q origin main
  git -C "$work" remote set-head origin main >/dev/null 2>&1
  printf '%s\n' "$work"
}

behind_branch() {  # <work>: leave <work> exactly two commits behind origin/main
  git -C "$1" reset -q --hard HEAD~2
}

run_check() {
  local home=$1 path=$2 out=$3
  shift 3
  local status=0
  env FM_CHECK_TIMEOUT=30 "$@" FM_HOME="$home" PATH="$path" FM_TOOL_UPDATE_INTERVAL=0 "$CHECK" >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "check exit"
}

# --- the latency-only sweep --------------------------------------------------

test_a_latency_only_sweep_produces_no_wake() {
  local home fake out i work record tools_json=""
  # Six watch clones, every remote slower than any bound the sweep can give it.
  # Pre-fix this printed six "origin did not answer where main points" lines
  # against a silent, up-to-date fleet; it must print nothing at all.
  home=$(make_home latency)
  fake="$TMP_ROOT/latency-fakebin"
  make_remote_fake_git "$fake"
  for i in 1 2 3 4 5 6; do
    work=$(git_fixture "slow-$i")
    [ -z "$tools_json" ] || tools_json="$tools_json,"
    tools_json="$tools_json{\"name\":\"tool$i\",\"git\":{\"repo\":\"$work\",\"remote\":\"origin\",\"branch\":\"main\"}}"
  done
  write_config "$home" "{\"tools\":[$tools_json]}"
  out="$home/out.txt"
  run_check "$home" "$(fixture_path "$fake")" "$out" FM_TOOL_UPDATE_PROBE_SECS=1 FM_TOOL_UPDATE_BUDGET_SECS=12
  [ ! -s "$out" ] || fail "a sweep whose only findings are probe timeouts produced a wake: $(cat "$out")"
  assert_present "$home/state/.tool-updates" "a silent latency sweep must still run to the end and write its record"
  record=$(cat "$home/state/.tool-updates")
  grep -qx 'reported=' "$home/state/.tool-updates" || fail "unverified timeouts must not be recorded as reported findings: $record"
  assert_not_contains "$record" "did not answer" "a timeout leaked into the report record"
  pass "a sweep whose only findings are probe timeouts wakes nobody"
}

# --- one slow remote must not starve the tools after it ----------------------

test_one_slow_remote_does_not_starve_the_tools_after_it() {
  local home fake out work behind report tools_json=""
  # Pre-fix, the first two slow remotes spent the whole budget on their own
  # probes: the sweep reported "check incomplete" for the third tool and never
  # reached the stale clone at all. The stale answer behind the slow remotes is
  # the finding that must survive them.
  home=$(make_home slice)
  fake="$TMP_ROOT/slice-fakebin"
  make_remote_fake_git "$fake"
  for work in "$(git_fixture slow-a)" "$(git_fixture slow-b)" "$(git_fixture slow-c)"; do
    [ -z "$tools_json" ] || tools_json="$tools_json,"
    tools_json="$tools_json{\"name\":\"${work##*/}\",\"git\":{\"repo\":\"$work\",\"remote\":\"origin\",\"branch\":\"main\"}}"
  done
  behind=$(git_fixture behind)
  behind_branch "$behind"
  tools_json="$tools_json,{\"name\":\"behind\",\"git\":{\"repo\":\"$behind\",\"remote\":\"origin\",\"branch\":\"main\"}}"
  write_config "$home" "{\"tools\":[$tools_json]}"
  out="$home/out.txt"
  run_check "$home" "$(fixture_path "$fake")" "$out" FM_TOOL_UPDATE_PROBE_SECS=4 FM_TOOL_UPDATE_BUDGET_SECS=8
  report=$(cat "$out")
  assert_contains "$report" "behind update available: local main is 2 commits behind origin/main" "the stale clone behind the slow remotes was starved out of the sweep"
  assert_not_contains "$report" "check incomplete" "one slow remote still ran the sweep budget out under the tools after it"
  assert_not_contains "$report" "did not answer" "the slow remotes' probe timeouts were reported"
  pass "one slow remote spends only its own slice and the tools after it still report"
}

# --- everything a probe actually answered keeps reporting --------------------

test_a_genuine_remote_error_still_reports() {
  local home fake out work report
  # A remote that answers with a real git failure is not latency: the probe got
  # its answer, and the finding is unchanged from upstream.
  home=$(make_home broken)
  fake="$TMP_ROOT/broken-fakebin"
  make_remote_fake_git "$fake"
  work=$(git_fixture broken-repo)
  write_config "$home" "{\"tools\":[{\"name\":\"app\",\"git\":{\"repo\":\"$work\",\"remote\":\"origin\",\"branch\":\"main\"}}]}"
  out="$home/out.txt"
  run_check "$home" "$(fixture_path "$fake")" "$out"
  report=$(cat "$out")
  assert_contains "$report" "app check failed: origin could not be reached or read from $work" "a genuine remote error was not reported"
  pass "a remote that answers with a genuine error still reports as a check failure"
}

test_a_local_probe_that_runs_and_stalls_still_reports() {
  local home fake out work report
  # The classification boundary: a local probe that ran and never answered is
  # a real tooling problem (upstream's own tests pin exactly this), whatever
  # the network is doing.
  home=$(make_home localstall)
  fake="$TMP_ROOT/localstall-fakebin"
  make_stalled_local_git "$fake"
  work=$(git_fixture localstall-repo)
  write_config "$home" "{\"tools\":[{\"name\":\"app\",\"git\":{\"repo\":\"$work\",\"remote\":\"origin\",\"branch\":\"main\"}}]}"
  out="$home/out.txt"
  run_check "$home" "$(fixture_path "$fake")" "$out" FM_TOOL_UPDATE_PROBE_SECS=1
  report=$(cat "$out")
  assert_contains "$report" "app check failed: $work did not answer whether it is a git repository" "a stalled local probe stopped reporting"
  pass "a local probe that ran and stalled still reports as upstream wrote it"
}

# --- the silence and the record stay honest together -------------------------

test_a_silent_sweep_does_not_mask_a_later_real_finding() {
  local home fake out work behind report tools_json=""
  # The record is the no-nag gate: unverified timeouts must not enter it, and a
  # real finding arriving on a later sweep must print even while the slow
  # remotes keep timing out in the same report.
  home=$(make_home followup)
  fake="$TMP_ROOT/followup-fakebin"
  make_remote_fake_git "$fake"
  for i in 1 2; do
    work=$(git_fixture "fslow-$i")
    [ -z "$tools_json" ] || tools_json="$tools_json,"
    tools_json="$tools_json{\"name\":\"tool$i\",\"git\":{\"repo\":\"$work\",\"remote\":\"origin\",\"branch\":\"main\"}}"
  done
  write_config "$home" "{\"tools\":[$tools_json]}"
  out="$home/out.txt"
  run_check "$home" "$(fixture_path "$fake")" "$out" FM_TOOL_UPDATE_PROBE_SECS=1 FM_TOOL_UPDATE_BUDGET_SECS=8
  [ ! -s "$out" ] || fail "the first slow sweep was not silent: $(cat "$out")"
  grep -qx 'reported=' "$home/state/.tool-updates" || fail "the first sweep recorded an unverified finding as reported: $(cat "$home/state/.tool-updates")"

  behind=$(git_fixture fbehind)
  behind_branch "$behind"
  write_config "$home" "{\"tools\":[$tools_json,{\"name\":\"behind\",\"git\":{\"repo\":\"$behind\",\"remote\":\"origin\",\"branch\":\"main\"}}]}"
  run_check "$home" "$(fixture_path "$fake")" "$out" FM_TOOL_UPDATE_PROBE_SECS=1 FM_TOOL_UPDATE_BUDGET_SECS=8
  report=$(cat "$out")
  assert_contains "$report" "behind update available: local main is 2 commits behind origin/main" "a real finding arriving after a silent timeout sweep was masked"
  pass "timeout silence records nothing, and a later real finding still reports"
}

fork_run_tests

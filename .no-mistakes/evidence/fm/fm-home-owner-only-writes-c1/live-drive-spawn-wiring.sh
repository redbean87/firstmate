#!/usr/bin/env bash
# Live drive of the spawn wiring records at the last-commit fix: a muse spawn
# (the shape whose subshell wrap broke exit-status propagation) must still
# succeed with and without prior session logs, and the state records the change
# wraps must be born 600 under an open caller umask.
set -u

ROOT=/Users/cortezashley/.no-mistakes/worktrees/26772a06f146/01M5F5DNEARND6JCZWPTKYNMGH
# shellcheck source=/dev/null
. "$ROOT/tests/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/tests/fixtures.sh"

FAILED=0
mode() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }
pass() { printf 'PASS  %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; FAILED=1; }
expect_mode() { local got; got=$(mode "$1" 2>/dev/null || echo missing); \
  if [ "$got" = "$2" ]; then pass "$3 ($1 mode=$got)"; else bad "$3 (want $2, got $got: $1)"; fi; }

TMP_ROOT=$(fm_test_tmproot fm-live-spawn-wiring)
SPAWN="$ROOT/bin/fm-spawn.sh"

# --- muse: the exact exit-status shape the last commit fixed -------------------
# The muse credential preflight proves META_API_KEY is visible in the tmux
# worker environment through `tmux show-environment`, so the stub must answer it
# (the same stub tests/fm-muse-harness.test.sh uses).
make_muse_fakebin() { # <dir> -> echoes the fakebin path
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  show-environment)
    [ "${FM_FAKE_WORKER_META_KEY:-}" = present ] || exit 1
    printf 'META_API_KEY=worker-key\n'
    exit 0
    ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then
        printf '%s\n' "$arg" >> "${FM_FAKE_LAUNCH_LOG:-/dev/null}"
        break
      fi
      prev=$arg
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/muse"
  chmod +x "$fakebin/muse"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

muse_spawn_case() { # <name> <prior-log:0|1> -> echoes "case|home|proj|wt|fakebin|id"
  local name=$1 prior=$2 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
  fakebin=$(make_muse_fakebin "$case_dir/fake")
  id="live-muse-$name"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" \
    "$home/xdgconfig" "$home/xdgdata" "$home/user-home"
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  if [ "$prior" = 1 ]; then
    mkdir -p "$home/xdgdata/muse/sessions/2026/08/05/prior"
    printf '{"schema_version":1,"payload":{"kind":"metadata","record":{"workspace_root":"%s"}}}\n' "$wt" \
      > "$home/xdgdata/muse/sessions/2026/08/05/prior/session.jsonl"
  fi
  printf '%s|%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$proj" "$wt" "$fakebin" "$id"
}

run_muse_spawn() { # <home> <proj> <wt> <fakebin> <id>
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5
  umask 022
  FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$home/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_WORKER_META_KEY=present FM_FAKE_LAUNCH_LOG="$home/launch.log" \
    META_API_KEY=test-key XDG_CONFIG_HOME="$home/xdgconfig" XDG_DATA_HOME="$home/xdgdata" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" muse --mode no-mistakes --yolo off 2>&1
}

for prior in 0 1; do
  rec=$(muse_spawn_case "prior$prior" "$prior")
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  out=$(run_muse_spawn "$home" "$proj" "$wt" "$fakebin" "$id"); rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "muse spawn succeeds under umask 022 (prior session logs: $prior)"
  else
    bad "muse spawn failed (prior session logs: $prior): $(printf '%s\n' "$out" | tail -n 3)"
    continue
  fi
  expect_mode "$home/state/$id.muse-session" 600 "muse session binding (prior session logs: $prior)"
  grep -F "workspace_root=$wt" "$home/state/$id.muse-session" >/dev/null \
    && pass "the muse binding records the task worktree" \
    || bad "the muse binding is malformed: $(head -n 3 "$home/state/$id.muse-session")"
  expect_mode "$home/state/$id.status" 600 "pre-created status record (muse)"
  expect_mode "$home/state/$id.meta" 600 "task record (muse)"
done

# --- claude: hook settings + task wiring under an open caller umask -----------
case_dir="$TMP_ROOT/claude"
home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"; id=live-claude-x1
fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake" claude gh-axi gh)
fm_test_spawn_home "$home" claude
fm_git_worktree "$proj" "$wt" "wt-live-claude"
fm_test_spawn_brief "$home" "$id"
out=$(umask 022; HOME="$home/user-home" fm_test_run_spawn "$home" "$wt" "$fakebin" \
  "$id" "$proj" --mode no-mistakes --yolo off); rc=$?
[ "$rc" -eq 0 ] && pass "claude spawn succeeds under umask 022" \
  || bad "claude spawn failed: $(printf '%s\n' "$out" | tail -n 3)"
expect_mode "$wt/.claude/settings.local.json" 644 "claude crewmate settings stay a worktree write at the caller umask (deliberate exclusion)"
expect_mode "$home/state/$id.status" 600 "pre-created status record (claude)"
expect_mode "$home/state/$id.meta" 600 "task record (claude)"
grep -F '"hooks"' "$wt/.claude/settings.local.json" >/dev/null \
  && pass "the claude crewmate settings still carry real hook wiring" \
  || bad "the claude settings lost their hook wiring"

printf '\n== overall: %s\n' "$([ "$FAILED" -eq 0 ] && echo ALL-PASS || echo FAILURES)"
exit "$FAILED"

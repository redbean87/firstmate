#!/usr/bin/env bash
# Upstream sync helper: fork/bin/fm-fork-sync prepare imports an upstream
# commit in its own worktree without touching the active checkout, records a
# backup ref, refuses to reuse one, and names every conflict's owner.
# Runs against a throwaway repository; the real tree is never touched.
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fork-sync)
mkdir -p "$TMP_ROOT"

# make_repo <name>: an "upstream" line (main) and the fork branch
# fork/stage1-enforcement with a hook-file edit and a fork-owned file, checked
# out, plus an untracked private note. Echoes the repo path.
make_repo() {
  local r="$TMP_ROOT/$1"
  mkdir -p "$r/bin" "$r/fork/bin"
  git -C "$r" init -q -b main
  git -C "$r" config user.email fork-test@invalid
  git -C "$r" config user.name fork-test
  printf 'spawn line 1\nspawn line 2\n' > "$r/bin/fm-spawn.sh"
  printf 'other line 1\n' > "$r/bin/other.sh"
  git -C "$r" add bin
  git -C "$r" commit -q -m base
  git -C "$r" checkout -q -b fork/stage1-enforcement
  cp "$ROOT/fork/bin/fm-fork-sync" "$r/fork/bin/"
  printf 'spawn line 1\n# fork hook\nspawn line 2\n' > "$r/bin/fm-spawn.sh"
  printf 'fork file\n' > "$r/fork/owned"
  git -C "$r" add bin fork
  git -C "$r" commit -q -m fork
  printf 'private\n' > "$r/notes.txt"
  printf '%s\n' "$r"
}

# upstream_commit <repo> <file> <content>: commit on main, echo its sha.
upstream_commit() {
  git -C "$1" checkout -q main
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -q -m "upstream $2"
  git -C "$1" rev-parse HEAD
  git -C "$1" checkout -q fork/stage1-enforcement
}

test_clean_import_leaves_active_checkout_alone() {
  local r sha out rc head_before
  r=$(make_repo clean)
  sha=$(upstream_commit "$r" bin/other.sh 'other line 1 upstream')
  head_before=$(git -C "$r" rev-parse HEAD)
  out=$("$r/fork/bin/fm-fork-sync" prepare "$sha" --worktree "$TMP_ROOT/clean-wt" 2>&1); rc=$?
  expect_code 0 "$rc" "a clean import must succeed"$'\n'"$out"
  assert_contains "$out" "merged: upstream ${sha:0:8}" "prepare must report the clean merge"
  assert_equals "$head_before" "$(git -C "$r" rev-parse HEAD)" "the active checkout's HEAD must not move"
  assert_equals fork/stage1-enforcement "$(git -C "$r" symbolic-ref --short HEAD)" "the active branch must not change"
  assert_equals "?? notes.txt" "$(git -C "$r" status --porcelain)" "the active working tree must be untouched"
  assert_equals "$head_before" "$(git -C "$r" rev-parse "refs/backup/stage1-enforcement-pre-sync-${sha:0:8}")" "the backup ref must name the pre-sync tip"
  git -C "$TMP_ROOT/clean-wt" merge-base --is-ancestor "$sha" HEAD || fail "the worktree must contain the upstream commit"
  assert_equals "other line 1 upstream" "$(cat "$TMP_ROOT/clean-wt/bin/other.sh")" "the worktree carries upstream's change"
  assert_equals "other line 1" "$(cat "$r/bin/other.sh")" "the active checkout keeps its own file"
  out=$("$r/fork/bin/fm-fork-sync" prepare "$sha" --worktree "$TMP_ROOT/clean-wt2" 2>&1); rc=$?
  expect_code 1 "$rc" "a second prepare of the same commit must refuse"
  assert_contains "$out" "already exists" "the refusal must name the existing backup ref"
  pass "sync: a clean import happens in its own worktree, records a backup ref, and refuses reuse"
}

test_conflicts_are_classified_and_left_in_progress() {
  local r sha out rc
  r=$(make_repo conflict)
  git -C "$r" checkout -q main
  printf 'spawn line 1\n# upstream change\nspawn line 2\n' > "$r/bin/fm-spawn.sh"
  mkdir -p "$r/fork"
  printf 'upstream writes here\n' > "$r/fork/owned"
  printf 'other upstream\n' > "$r/bin/other.sh"
  git -C "$r" add bin fork/owned
  git -C "$r" commit -q -m upstream
  sha=$(git -C "$r" rev-parse HEAD)
  git -C "$r" checkout -q fork/stage1-enforcement
  printf 'other fork edit\n' > "$r/bin/other.sh"
  git -C "$r" commit -q -am "fork edits an upstream file"
  out=$("$r/fork/bin/fm-fork-sync" prepare "$sha" --worktree "$TMP_ROOT/conflict-wt" 2>&1); rc=$?
  expect_code 3 "$rc" "a conflicting import must exit 3"$'\n'"$out"
  assert_contains "$out" "fork-owned fork/owned" "a fork-owned conflict must be named"
  assert_contains "$out" "hook file  bin/fm-spawn.sh" "a hook-file conflict must be named"
  assert_contains "$out" "upstream   bin/other.sh" "an upstream-owned conflict must be named"
  [ -f "$(git -C "$TMP_ROOT/conflict-wt" rev-parse --git-dir)/MERGE_HEAD" ] || fail "the merge must be left in progress"
  assert_equals "?? notes.txt" "$(git -C "$r" status --porcelain)" "the active working tree must be untouched"
  pass "sync: conflicts stay in progress in the worktree, each named fork-owned, hook file, or upstream"
}

test_missing_commit_refuses_without_side_effects() {
  local r out rc
  r=$(make_repo missing)
  out=$("$r/fork/bin/fm-fork-sync" prepare 0123456789abcdef0123456789abcdef01234567 --worktree "$TMP_ROOT/missing-wt" 2>&1); rc=$?
  expect_code 1 "$rc" "an absent commit must refuse"
  assert_contains "$out" "fetch it first" "the refusal must say to fetch"
  [ ! -e "$TMP_ROOT/missing-wt" ] || fail "no worktree may be created"
  [ -z "$(git -C "$r" for-each-ref refs/backup)" ] || fail "no backup ref may be written"
  pass "sync: an unfetched commit refuses before writing anything"
}

fork_run_tests

#!/usr/bin/env bash
# HK8 (fork/bin/fm-registry-key): a ship spawn resolves standing posture
# against the project's registry key, not blindly against the directory
# basename.
#
# A project directory that IS this home's code root - whose basename is not a
# registry key - resolves to the registry entry that declares itself the
# home's own code root, so a correct direct-PR dispatch prints no deviation
# notice, while the branch-prefix notice proves the posture block ran with the
# resolved key. A directory that is neither the home nor registered keeps
# upstream's unregistered default and its notice, and a real drop below a
# registered posture is still announced.
#
# Every case drives the real bin/fm-spawn.sh (which runs the real
# fork/bin/fm-registry-key and the real bin/fm-project-mode.sh) against a
# temporary registry, with a tmux that exits non-zero so the spawn stops at
# endpoint creation and creates no record. Nothing under test is mocked; no
# network is used.
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-role-lib.sh
. "$ROOT/bin/fm-role-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-fork-registry-key)
mkdir -p "$TMP_ROOT"

# The registry line this home's data/projects.md gives the Firstmate
# repository. Its description is what declares the entry the resolver falls
# back to, and branch=fix/ proves the resolved entry (not the basename) is
# read end to end.
HOME_ENTRY=$(cat <<'EOF'
- firstmate [direct-PR +yolo branch=fix/] - The Firstmate tooling repository itself, the supervisor home's own code root rather than a projects/ clone (added 2026-11-02)
EOF
)

# make_case <name> [<registry-line>...]: a home holding that registry plus a
# tmux that exits non-zero. Echoes "<home>|<fakebin>".
make_case() {
  local name=$1 home fakebin
  shift
  home="$TMP_ROOT/$name/home"
  fakebin="$TMP_ROOT/$name/bin"
  mkdir -p "$home/data" "$home/state" "$home/config" "$fakebin"
  touch "$home/state/.last-watcher-beat"
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" > "$home/data/projects.md"
  fi
  printf '%s\n' "$home|$fakebin"
}

# write_brief <home> <id> <mode>: a filled brief whose delivery contract
# records <mode>.
write_brief() {
  mkdir -p "$1/data/$2"
  cat > "$1/data/$2/brief.md" <<EOF
# Task
## Captain's intent
Exercise the registry-key posture resolution.

## Firstmate spec
Verify the spawn's standing-posture lookup.

# Definition of done
Delivery contract: mode=$3
EOF
}

# run_spawn <home> <fakebin> <spawn-args...>: the spawn environment the
# upstream delivery-contract suite uses, with backend tmux and the refusing
# fake tmux on PATH, so a spawn that clears every check still creates nothing.
run_spawn() {
  local home=$1 fakebin=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

test_home_code_root_resolves_the_registered_home_entry() {
  local rec home fakebin id out target
  rec=$(make_case home-root "$HOME_ENTRY")
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  # This spawn's project IS the repository, so it passes the same
  # self-publication gate the real home passes through its own role file
  # (bin/fm-role-lib.sh); the scope comes from the repository's own identity.
  target=$(fm_role_publication_target "$ROOT")
  [ -n "$target" ] || fail "could not determine the publication target of $ROOT"
  printf 'maintainer %s\n' "$target" > "$home/config/firstmate-role"
  id=hk8-home-a1
  write_brief "$home" "$id" direct-PR
  out=$(run_spawn "$home" "$fakebin" "$id" "$ROOT" claude --mode direct-PR --yolo on)
  assert_not_contains "$out" "less rigor than the captain's standing posture" \
    "a correct direct-PR dispatch against the home code root must not print the deviation notice"
  assert_contains "$out" "while firstmate registers the ship-branch prefix 'fix/'" \
    "the posture block must run to completion with the key resolved to the registered home entry"
  assert_absent "$home/state/$id.meta" "the refusing tmux must keep this fixture from creating a record"
  pass "hk8: the home code root resolves to the registered firstmate posture"
}

test_unregistered_project_keeps_the_upstream_default_and_notice() {
  local rec home fakebin id out proj
  rec=$(make_case unregistered "$HOME_ENTRY")
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  proj="$TMP_ROOT/unregistered/unreg-proj"
  fm_git_init_commit "$proj"
  id=hk8-unreg-b1
  write_brief "$home" "$id" direct-PR
  out=$(run_spawn "$home" "$fakebin" "$id" "$proj" claude --mode direct-PR --yolo off)
  assert_contains "$out" "less rigor than the captain's standing posture" \
    "a directory that is neither the home nor registered must keep the deviation notice"
  assert_contains "$out" "the standing posture for unreg-proj is no-mistakes" \
    "the unregistered default must still be keyed on the directory basename"
  pass "hk8: an unregistered directory keeps upstream's no-mistakes default and its notice"
}

test_a_real_drop_below_a_registered_posture_is_still_announced() {
  local rec home fakebin id out proj
  rec=$(make_case registered-drop "$HOME_ENTRY" \
    "- proj [no-mistakes] - fixture (added 2026-11-01)")
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  proj="$TMP_ROOT/registered-drop/proj"
  fm_git_init_commit "$proj"
  id=hk8-drop-c1
  write_brief "$home" "$id" local-only
  out=$(run_spawn "$home" "$fakebin" "$id" "$proj" claude --mode local-only --yolo off)
  assert_contains "$out" "less rigor than the captain's standing posture" \
    "a real drop below a registered posture must still be announced"
  assert_contains "$out" "the standing posture for proj is no-mistakes" \
    "the registered posture must be looked up under the directory's own key"
  pass "hk8: a real drop below a registered posture is still announced"
}

fork_run_tests

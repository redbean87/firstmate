#!/usr/bin/env bash
# Hook wiring: fork/bin/fm-fork-hook-check passes on this tree and detects each
# way the two upstream integration points can go missing, drift, or move.
# Mutations run on temporary copies; the real tree is never edited.
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/fork/bin/fm-fork-hook-check"
TMP_ROOT=$(fm_test_tmproot fm-fork-hook-wiring)
mkdir -p "$TMP_ROOT"

# copy_tree <name>: a minimal tree holding the three hooked files, the canonical
# blocks, and one other upstream bin file. Echoes its root.
copy_tree() {
  local t="$TMP_ROOT/$1"
  mkdir -p "$t/bin" "$t/fork/hooks"
  cp "$ROOT/bin/fm-spawn.sh" "$ROOT/bin/fm-control.sh" "$ROOT/bin/fm-watch.sh" "$ROOT/bin/fm-send.sh" "$t/bin/"
  cp "$ROOT/fork/hooks/"*.block "$t/fork/hooks/"
  printf '%s\n' "$t"
}

# edit <file> <python-expression-on-s>: rewrite a copied file in place.
edit() {
  python3 - "$1" "$2" <<'PY'
import sys
p, expr = sys.argv[1], sys.argv[2]
s = open(p).read()
hk1 = open(p.rsplit("/bin/", 1)[0] + "/fork/hooks/hk1-spawn.block").read()
hk2 = open(p.rsplit("/bin/", 1)[0] + "/fork/hooks/hk2-control.block").read()
s2 = eval(expr, {"s": s, "hk1": hk1, "hk2": hk2})
assert s2 != s, "mutation did not change the file"
open(p, "w").write(s2)
PY
}

expect_detected() {  # <root> <expected FAIL text> <label>
  local out rc
  out=$("$CHECK" --root "$1" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "$3: the hook check did not fail"$'\n'"$out"
  assert_contains "$out" "FAIL: $2" "$3: the hook check must name the problem"
}

test_real_tree_passes() {
  local out rc
  out=$("$CHECK" 2>&1); rc=$?
  expect_code 0 "$rc" "the hook check must pass on this tree"$'\n'"$out"
  pass "wiring: both hooks present, identical, and at their lifecycle points in this tree"
}

test_detects_missing_hk1() {
  local t; t=$(copy_tree no-hk1)
  edit "$t/bin/fm-spawn.sh" 's.replace(hk1, "")'
  expect_detected "$t" "HK1: expected exactly one hook block" "missing HK1"
  pass "wiring: a removed HK1 is detected"
}

test_detects_duplicate_hk1() {
  local t; t=$(copy_tree dup-hk1)
  edit "$t/bin/fm-spawn.sh" 's.replace(hk1, hk1 + hk1, 1)'
  expect_detected "$t" "HK1: expected exactly one hook block" "duplicated HK1"
  pass "wiring: a duplicated HK1 is detected"
}

test_detects_edited_hk1() {
  local t; t=$(copy_tree edit-hk1)
  edit "$t/bin/fm-spawn.sh" 's.replace("|| exit 1\nfi\n# <<< fork launch-policy hook HK1", "|| true\nfi\n# <<< fork launch-policy hook HK1")'
  expect_detected "$t" "HK1: hook block in bin/fm-spawn.sh differs" "edited HK1"
  pass "wiring: an HK1 block that no longer refuses (|| true) is detected"
}

test_detects_hk1_moved_after_render() {
  local t; t=$(copy_tree late-hk1)
  # shellcheck disable=SC2016 # Python source, not shell expansion
  edit "$t/bin/fm-spawn.sh" 's.replace(hk1, "").replace("\nW=\"fm-$ID\"\n", "\n" + hk1 + "W=\"fm-$ID\"\n", 1)'
  expect_detected "$t" "HK1: block must sit after project capacity admission" "HK1 after the launch-brief render"
  pass "wiring: HK1 moved past the launch-brief render is detected"
}

test_detects_contract_variable_reassigned_after_hk1() {
  local t; t=$(copy_tree late-model)
  # shellcheck disable=SC2016 # Python source, not shell expansion
  edit "$t/bin/fm-spawn.sh" 's.replace("\nW=\"fm-$ID\"\n", "\nMODEL=late\nW=\"fm-$ID\"\n", 1)'
  expect_detected "$t" "HK1: a contract variable is reassigned after the block" "late MODEL assignment"
  pass "wiring: a contract variable reassigned between HK1 and launch is detected"
}

test_detects_lost_upstream_anchor() {
  local t; t=$(copy_tree no-anchor)
  edit "$t/bin/fm-spawn.sh" 's.replace("# Project capacity admission", "# Capacity admission")'
  expect_detected "$t" "HK1: an upstream anchor is gone" "renamed upstream anchor"
  pass "wiring: a vanished upstream anchor is reported for re-anchoring"
}

test_detects_hk2_after_checkpoint() {
  local t; t=$(copy_tree late-hk2)
  edit "$t/bin/fm-control.sh" 's.replace(hk2, "").replace("  safe_checkpoint\n", "  safe_checkpoint\n" + hk2, 1)'
  expect_detected "$t" "HK2: block must come before safe_checkpoint and do_exit" "HK2 after the checkpoint"
  pass "wiring: HK2 moved after safe_checkpoint (after the agent could stop) is detected"
}

test_detects_hk2_outside_relaunch() {
  local t; t=$(copy_tree outside-hk2)
  edit "$t/bin/fm-control.sh" 's.replace(hk2, "").replace("\ndo_relaunch() {\n", "\n" + hk2 + "do_relaunch() {\n", 1)'
  expect_detected "$t" "HK2: block must sit inside do_relaunch()" "HK2 outside do_relaunch"
  pass "wiring: HK2 outside do_relaunch() is detected"
}

test_detects_hk2_before_profile() {
  local t; t=$(copy_tree early-hk2)
  edit "$t/bin/fm-control.sh" 's.replace("  resolve_relaunch_profile\n", "", 1)'
  expect_detected "$t" "HK2: block must follow resolve_relaunch_profile" "HK2 before the relaunch target is resolved"
  pass "wiring: HK2 judging an unresolved relaunch target is detected"
}

test_detects_fork_reference_elsewhere() {
  local t; t=$(copy_tree stray)
  # shellcheck disable=SC2016 # a literal stray reference is the point
  printf '\n"$FM_ROOT/fork/bin/fm-launch-policy"\n' >> "$t/bin/fm-send.sh"
  expect_detected "$t" "fork references outside the two hook files" "stray fork call"
  pass "wiring: a fork reference in any other upstream bin/ file is detected"
}

test_base_detects_other_upstream_edits() {
  local t out rc
  t=$(copy_tree base)
  git -C "$t" init -q
  git -C "$t" config user.email fork-test@invalid
  git -C "$t" config user.name fork-test
  cp "$t/bin/fm-spawn.sh" "$t/spawn.hooked"
  cp "$t/bin/fm-control.sh" "$t/control.hooked"
  edit "$t/bin/fm-spawn.sh" 's.replace(hk1, "")'
  edit "$t/bin/fm-control.sh" 's.replace(hk2, "")'
  git -C "$t" add bin
  git -C "$t" commit -q -m upstream
  mv "$t/spawn.hooked" "$t/bin/fm-spawn.sh"
  mv "$t/control.hooked" "$t/bin/fm-control.sh"
  out=$("$CHECK" --root "$t" --base HEAD 2>&1); rc=$?
  expect_code 0 "$rc" "--base must accept a tree that differs only by the two blocks"$'\n'"$out"
  printf '# local tweak\n' >> "$t/bin/fm-send.sh"
  out=$("$CHECK" --root "$t" --base HEAD 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "--base must reject an edit to a third upstream file"
  assert_contains "$out" "upstream-owned files differing" "--base must name the extra file"
  git -C "$t" checkout -q -- bin/fm-send.sh
  printf '# tweak\n' >> "$t/bin/fm-control.sh"
  out=$("$CHECK" --root "$t" --base HEAD 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "--base must reject a hooked file changed beyond its block"
  pass "wiring: --base accepts exactly the two blocks and rejects any other upstream edit"
}

fork_run_tests

#!/usr/bin/env bash
# fork/tests/fm-fork-composer-hud.test.sh - HK10, the themed-HUD pre-filter:
# the committed fixtures are sanitized captures of one real idle herdr Claude
# pane carrying a local theme's HUD footer (fork/tests/fixtures/, ANSI and
# plain forms), and they pin both directions of the classifier's verdict
# through the exact call bin/backends/herdr.sh makes - its capability
# descriptor and its lazily-probed identity - plus the content extractor that
# fm-send's doorbell proof reads. Zero network and zero live pane: the
# fixture is fed straight through bin/fm-composer-lib.sh.
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

FIXTURES="$ROOT/fork/tests/fixtures"

# herdr_caps <styled>: herdr's capability descriptor for one capture form.
herdr_caps() {
  printf 'styled=%s\ncursor=0\nidentity=1\ncortex=ask' "$1"
}

# hud_fixture_with_line: the ANSI fixture rewritten so the composer glyph row
# carries one real line of typed text - the negative control's pending draft.
hud_fixture_with_line() {
  python3 - "$1" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
glyph = b"\xe2\x9d\xaf\xc2\xa0\x1b[0m"  # bare claude glyph + NBSP + reset
assert data.count(glyph) == 1, "fixture must hold exactly one bare composer row"
sys.stdout.buffer.write(data.replace(glyph, glyph[:-5] + b"hello captain\x1b[0m"))
PY
}

test_idle_hud_fixture_classifies_empty() {
  local cap out
  cap=$(cat "$FIXTURES/claude-hud-footer.ansi")
  out=$(fm_composer_classify_screen "$(herdr_caps 1)" "$cap" '' "$(printf 'claude\tidle')")
  assert_equals empty "$out" "an idle Claude pane with the themed HUD footer must classify empty"
  out=$(fm_composer_classify_screen "$(herdr_caps 1)" "$cap" '' probe-absent)
  assert_equals empty "$out" "an absent identity probe must not demote the idle HUD fixture"
  cap=$(cat "$FIXTURES/claude-hud-footer.plain")
  out=$(fm_composer_classify_screen "$(herdr_caps 0)" "$cap" '' "$(printf 'claude\tidle')")
  assert_equals empty "$out" "the plain capture form of the same pane must classify empty"
  pass "idle HUD fixture classifies empty in both capture forms and across identity probes"
}

test_composer_line_over_hud_fixture_is_pending() {
  local cap out
  cap=$(hud_fixture_with_line "$FIXTURES/claude-hud-footer.ansi")
  out=$(fm_composer_classify_screen "$(herdr_caps 1)" "$cap" '' "$(printf 'claude\tidle')")
  assert_equals pending "$out" "a real composer line over the HUD footer must classify pending"
  pass "negative control: a real composer line over the HUD footer reads pending"
}

test_hud_fixture_content_extraction_is_empty() {
  local held caps
  caps=$(herdr_caps 1)
  held=$(FM_COMPOSER_GHOST_LUMA_MAX=0 fm_composer_extract_selected_content "$caps" \
    "$(cat "$FIXTURES/claude-hud-footer.ansi")")
  assert_equals "" "$held" "the doorbell content proof must read no held text on the idle HUD fixture"
  held=$(FM_COMPOSER_GHOST_LUMA_MAX=0 fm_composer_extract_selected_content "$caps" \
    "$(hud_fixture_with_line "$FIXTURES/claude-hud-footer.ansi")")
  assert_contains "$held" "hello captain" "a real composer line must survive content extraction"
  pass "content extraction: the idle fixture holds nothing, the typed line is kept (doorbell proof path)"
}

fork_run_tests

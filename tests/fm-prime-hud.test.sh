#!/usr/bin/env bash
# Behavior checks for the Metroid Prime HUD Pi extension (.pi/extensions/fm-prime-hud.ts): honest unknown readouts, tank thresholds, beam fallback, hazard precedence and clearing, the destructive-command heuristic's safe and unsafe forms, registration and lifecycle wiring, and width truncation at 40, 80, and 160 columns, executed against the colocated node:test suite with the installed Pi packages linked into a fixture directory.
# The colocated suite lives in .pi/extensions/test/ because Pi auto-loads every top-level .ts file in .pi/extensions/ as an extension, and the subdirectory is skipped the same way lib/ is (no index entry point).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found for fm-prime-hud extension tests"; exit 0; }
command -v npm >/dev/null 2>&1 || { echo "skip: npm not found for fm-prime-hud extension tests"; exit 0; }

# Probe the runtime's TypeScript support instead of assuming a Node version: run a tiny .ts
# file with no flags first (Node 23.6+ and 24 strip types by default), then with
# --experimental-strip-types (Node 22.6+), and skip when neither works.
TS_PROBE_ROOT=$(fm_test_tmproot fm-prime-hud-tsprobe) || {
  echo "skip: could not create a TypeScript probe directory for fm-prime-hud extension tests"
  exit 0
}
printf '%s\n' 'const probe: number = 1;' 'void probe;' >"$TS_PROBE_ROOT/probe.ts"

NODE_TS_ARGS=
if node "$TS_PROBE_ROOT/probe.ts" >/dev/null 2>&1; then
  :
elif node --experimental-strip-types "$TS_PROBE_ROOT/probe.ts" >/dev/null 2>&1; then
  NODE_TS_ARGS=--experimental-strip-types
else
  echo "skip: node lacks TypeScript support needed for the fm-prime-hud extension tests"
  exit 0
fi

PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}
if [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
  # Volta-managed installs keep the package outside npm's global root.
  PI_PACKAGE_DIR="$HOME/.volta/tools/image/packages/@earendil-works/pi-coding-agent/lib/node_modules/@earendil-works/pi-coding-agent"
fi
if [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
  echo "skip: installed @earendil-works/pi-coding-agent package not found for fm-prime-hud extension tests (set FM_PI_PACKAGE_DIR to override)"
  exit 0
fi

# Pi 1.x hoists shared dependencies to the install root instead of nesting them
# under pi-coding-agent/node_modules, so accept either layout for pi-tui.
NESTED="$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui"
HOISTED="$(dirname "$(dirname "$PI_PACKAGE_DIR")")/@earendil-works/pi-tui"
if [ -d "$NESTED" ]; then
  PI_TUI_DIR=$NESTED
elif [ -d "$HOISTED" ]; then
  PI_TUI_DIR=$HOISTED
else
  echo "not ok - installed Pi package is missing @earendil-works/pi-tui" >&2
  exit 1
fi

TMP_ROOT=$(fm_test_tmproot fm-prime-hud) || exit 1
trap fm_test_cleanup EXIT

cp "$ROOT/.pi/extensions/fm-prime-hud.ts" "$TMP_ROOT/fm-prime-hud.ts" || exit 1
mkdir -p "$TMP_ROOT/test"
cp "$ROOT/.pi/extensions/test/fm-prime-hud.test.ts" "$TMP_ROOT/test/fm-prime-hud.test.ts" || exit 1
printf '%s\n' '{"type":"module"}' >"$TMP_ROOT/package.json"
mkdir -p "$TMP_ROOT/node_modules/@earendil-works"
ln -s "$PI_TUI_DIR" "$TMP_ROOT/node_modules/@earendil-works/pi-tui"

version=$(node -p "require('$PI_PACKAGE_DIR/package.json').version" 2>/dev/null || printf 'unknown')
echo "# fm-prime-hud extension tests against Pi $version"

cd "$TMP_ROOT" || exit 1
# shellcheck disable=SC2086 # NODE_TS_ARGS is empty or a single literal flag.
node $NODE_TS_ARGS --test test/fm-prime-hud.test.ts
status=$?
exit "$status"

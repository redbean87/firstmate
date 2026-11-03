#!/usr/bin/env bash
# Shared fixtures for the moot-wake fork tests (fm-fork-moot-wake*.test.sh).
#
# moot_install_fixture builds a throwaway root holding the REAL upstream Pi
# watch extension (with the library files it imports, resolved through stub
# Pi packages) and the REAL fork extension, so the e2e test proves the offer
# seam between them rather than a copy of it. moot_write_arm installs a stub
# bin/fm-watch-arm.sh whose first arm closes with a chosen actionable line and
# whose later arms stay alive and ready. No test touches a live fleet.

# shellcheck disable=SC2034 # read by the test files that source this library
MOOT_FAKE_PI="$ROOT/fork/tests/moot-wake-fake-pi.mjs"
MOOT_FORK_EXT="$ROOT/fork/wake-guard/fm-pi-moot-wake.ts"
export NODE_NO_WARNINGS=1

moot_install_fixture() {  # <repo>
  local repo=$1 lib
  mkdir -p \
    "$repo/.pi/extensions/lib" "$repo/fork/wake-guard" "$repo/bin" \
    "$repo/node_modules/@earendil-works/pi-coding-agent" \
    "$repo/node_modules/@earendil-works/pi-tui" \
    "$repo/node_modules/typebox"
  cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$repo/.pi/extensions/"
  for lib in fm-branch-dispatch fm-native-contract fm-async-exec fm-calm-visibility fm-operational-input; do
    cp "$ROOT/.pi/extensions/lib/$lib.ts" "$repo/.pi/extensions/lib/$lib.ts"
  done
  cp "$MOOT_FORK_EXT" "$repo/fork/wake-guard/"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/"
  chmod +x "$repo/bin/fm-operational-input.sh"
  printf '%s\n' '{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}' \
    > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json"
  printf '%s\n' 'export function getMarkdownTheme(){return {};}' \
    'export class UserMessageComponent{render(){return [];}invalidate(){}}' \
    > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js"
  printf '%s\n' '{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}' \
    > "$repo/node_modules/@earendil-works/pi-tui/package.json"
  printf '%s\n' 'export class Box{addChild(){}clear(){}setBgFn(){}}' \
    'export class Container{}' 'export class Text{}' \
    > "$repo/node_modules/@earendil-works/pi-tui/index.js"
  printf '%s\n' '{"name":"typebox","type":"module","exports":"./index.js"}' \
    > "$repo/node_modules/typebox/package.json"
  printf '%s\n' 'export const Type={Object(p){return {type:"object",properties:p,additionalProperties:false};}};' \
    > "$repo/node_modules/typebox/index.js"
}

# moot_write_arm <repo> <stub-dir> <first-arm-line> [<drain-first>] [<later-arm-mode>]
#   first-arm-line  the actionable line the first arm prints before it exits
#   drain-first     "drain" empties the wake queue just before that line (a
#                   drain winning the race against delivery); anything else
#                   leaves the queue alone
#   later-arm-mode  "ok" (default): later arms start, stay ready, and idle
#                   "fail": later arms print a watcher failure and exit 1
# Records every arm start and every --handling-delivered call in
# <stub-dir>/calls so a test can prove the handshake and the restore ran.
moot_write_arm() {
  local repo=$1 stub=$2 line=$3 drain=${4:-keep} later=${5:-ok}
  mkdir -p "$stub"
  cat > "$repo/bin/fm-watch-arm.sh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --handling-delivered ]; then
  echo "handling-delivered \$*" >> "$stub/calls"
  exit 0
fi
n=\$(( \$(cat "$stub/count" 2>/dev/null || echo 0) + 1 ))
echo "\$n" > "$stub/count"
echo "arm \$n" >> "$stub/calls"
if [ "\$n" -gt 1 ] && [ "$later" = fail ]; then
  echo "watcher: FAILED - stub successor cannot start"
  exit 1
fi
echo "watcher: started pid=\$\$ recovery-generation=gen\$n"
if [ "\$n" = 1 ]; then
  sleep 0.3
  [ "$drain" = drain ] && : > "\$FM_STATE_OVERRIDE/.wake-queue"
  echo "$line"
  exit 0
fi
while [ -e "$stub/count" ]; do sleep 0.2; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
}

# moot_queue_row <state-dir> [<reason>]: one valid queued row, as
# fm_wake_append writes it (epoch, sequence, kind, key, payload).
moot_queue_row() {
  printf '%s\t1\tcheck\tseed\t%s\n' "$(date +%s)" "${2:-check: seed row}" > "$1/.wake-queue"
}

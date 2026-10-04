#!/usr/bin/env bash
# Push the declared inherited-material allowlist to one remote secondmate route.
# Usage: fm-remote-inherit-push.sh <secondmate-id> <generation>
#
# The item set is derived from the ONE declared owner
# (FM_INHERITABLE_CONFIG in bin/fm-config-inherit-lib.sh), the same declaration
# the receiving bin/fm-remote-inherit.sh enforces, so the two implementations in
# one code revision cannot drift silently. Different local and remote revisions
# fail closed as documented by that owner. FM_CONFIG_INHERIT_LIVE=1 marks a live
# convergence push into an already-running home and skips session-scoped items,
# exactly as the local propagation path does.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}
file_link_count() {
  if [ "$(uname)" = Darwin ]; then /usr/bin/stat -f %l "$1" 2>/dev/null; else stat -c %h "$1" 2>/dev/null; fi
}
[ "$#" -eq 2 ] || { echo "usage: fm-remote-inherit-push.sh <secondmate-id> <generation>" >&2; exit 2; }
ID=$1
GENERATION=$2
case "$ID" in ''|*[!A-Za-z0-9._-]*) die "invalid secondmate id: $ID" ;; esac
case "$GENERATION" in ''|*[!0-9]*) die "generation must be a positive integer" ;; esac
[ "${#GENERATION}" -le 18 ] && [ "$GENERATION" -ge 1 ] || die "generation is outside the supported range"
REMOTE=$(secondmate_registry_field "$DATA/secondmates.md" "$ID" remote 2>/dev/null || true)
[ "$REMOTE" = 1 ] || die "secondmate $ID is not a remote route"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-remote-inherit-push.XXXXXX") || die "cannot create inheritance staging directory"
trap 'rm -rf -- "$TMP"' EXIT
EMPTY="$TMP/empty"
: > "$EMPTY"
EMPTY_HASH=$(sha256_file "$EMPTY") || die "cannot hash empty inheritance payload"

ITEMS=$(fm_config_inherit_items)
# Push-avoidance manifest: a successful push records the exact per-item payload
# (command, byte length, digest) beside the generation counter, so a later push
# whose inheritable material is byte-identical can report every item unchanged
# without spending one SSH round trip per item. The manifest is a pure sender-side
# cache: any missing, malformed, or mismatching record falls back to a full push,
# and a failed push never updates it, so the remote side cannot be left behind.
# Callers hold the per-route inheritance transaction lock while this runs, which
# serializes manifest read-modify-write cycles for one route. A remote home
# mutated outside a parent-driven push is not detected here; every parent-driven
# mutation (provision, update, rollback, config push, spawn) goes through this
# script and refreshes the manifest on success.
STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
MANIFEST="$STATE_DIR/.remote-inherit-$ID.manifest"
RECORDS="$TMP/records"
: > "$RECORDS"
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  if [ "${FM_CONFIG_INHERIT_LIVE:-0}" = 1 ]; then
    case "$rel" in
      config/*)
        if fm_config_inherit_item_session_scoped "${rel#config/}"; then
          printf 'unchanged: %s\n' "$rel"
          printf '%s\tskip\n' "$rel" >> "$RECORDS"
          continue
        fi
        ;;
    esac
  fi
  case "$rel" in
    config/*) source="$CONFIG/${rel#config/}" ;;
    data/*) source="$DATA/${rel#data/}" ;;
  esac
  source_present=$(fm_config_source_present "$source") || exit 1
  if [ "$source_present" = 1 ]; then
    [ -f "$source" ] && [ ! -L "$source" ] || die "inherited source is unsafe: $source"
    [ "$(file_link_count "$source")" = 1 ] || die "inherited source is hardlinked: $source"
    if [ "$rel" = data/captain-shared.md ]; then
      if ! missing=$(shared_captain_header_valid "$source"); then
        reason="shared captain preferences have no valid primary-authoritative header"
        [ -z "$missing" ] || reason="$reason: missing \"$missing\""
        die "$reason"
      fi
    fi
    snapshot="$TMP/$(printf '%s' "$rel" | tr '/' '_')"
    cp -p -- "$source" "$snapshot" || die "cannot snapshot inherited source: $source"
    [ -f "$snapshot" ] && [ ! -L "$snapshot" ] || die "inherited source snapshot is unsafe: $source"
    bytes=$(LC_ALL=C wc -c < "$snapshot" | tr -d ' ')
    hash=$(sha256_file "$snapshot") || die "cannot hash inherited source: $source"
    printf '%s\tput\t%s\t%s\n' "$rel" "$bytes" "$hash" >> "$RECORDS"
  else
    printf '%s\tabsent\t0\t%s\n' "$rel" "$EMPTY_HASH" >> "$RECORDS"
  fi
done <<EOF
$ITEMS
EOF

manifest_matches() {
  local line=0 schema generation
  [ -f "$MANIFEST" ] && [ ! -L "$MANIFEST" ] || return 1
  {
    IFS= read -r schema || return 1
    IFS= read -r generation || return 1
    [ "$schema" = schema=fm-remote-inherit-manifest.v1 ] || return 1
    case "$generation" in generation=*[!0-9]*|'generation=') return 1 ;; esac
    while IFS= read -r line; do
      [ -n "$line" ] || return 1
      case "$line" in *$'\t'*$'\t'*$'\t'*) ;; *) return 1 ;; esac
    done
  } < "$MANIFEST" || return 1
  tail -n +3 -- "$MANIFEST" > "$TMP/manifest-records" || return 1
  grep -v $'\tskip$' -- "$RECORDS" > "$TMP/desired-records" 2>/dev/null || true
  cmp -s -- "$TMP/manifest-records" "$TMP/desired-records"
}

write_manifest() {
  local tmp_manifest
  [ -d "$STATE_DIR" ] && [ ! -L "$STATE_DIR" ] || return 1
  tmp_manifest=$(umask 077; mktemp "$STATE_DIR/.remote-inherit-manifest.XXXXXX") || return 1
  {
    printf 'schema=fm-remote-inherit-manifest.v1\n'
    printf 'generation=%s\n' "$GENERATION"
    grep -v $'\tskip$' -- "$RECORDS"
  } > "$tmp_manifest" || { rm -f -- "$tmp_manifest"; return 1; }
  chmod 600 "$tmp_manifest" || { rm -f -- "$tmp_manifest"; return 1; }
  mv -f -- "$tmp_manifest" "$MANIFEST" || { rm -f -- "$tmp_manifest"; return 1; }
}

if manifest_matches; then
  while IFS=$'\t' read -r rel _command _bytes _hash; do
    [ -n "$rel" ] || continue
    printf 'unchanged: %s\n' "$rel"
  done < "$TMP/desired-records"
  exit 0
fi

while IFS=$'\t' read -r rel command bytes hash; do
  [ -n "$rel" ] || continue
  case "$command" in skip) continue ;; esac
  snapshot="$TMP/$(printf '%s' "$rel" | tr '/' '_')"
  case "$command" in
    put)
      [ -f "$snapshot" ] && [ ! -L "$snapshot" ] || die "inherited source snapshot is unsafe: $rel"
      "$SCRIPT_DIR/fm-on.sh" --stdin "$ID" fm-remote-inherit.sh put "$rel" "$bytes" "$hash" "$GENERATION" < "$snapshot"
      ;;
    absent)
      # This loop's heredoc is its control stream, not remote command input.
      "$SCRIPT_DIR/fm-on.sh" "$ID" fm-remote-inherit.sh absent "$rel" 0 "$EMPTY_HASH" "$GENERATION" < /dev/null
      ;;
    *) die "inherited record is malformed: $rel" ;;
  esac
done < "$RECORDS"

# A cache write must never fail a successful transfer: without it the next push
# simply transfers again. It stays silent so machine-read output is unaffected.
write_manifest || true

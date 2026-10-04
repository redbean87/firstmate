#!/usr/bin/env bash
# Scenario 4 (core intent): a warm ~/.npm-style download cache stops the CI
# global installs from paying for fresh downloads. Drives the REAL npm with
# the same two packages ci.yml installs (tasks-axi, @earendil-works/pi-coding-agent)
# in fully isolated cache/prefix dirs.
# Scenario 5 (adversarial): a cache MISS must behave exactly like today's
# uncached flow (empty cache + plain install works), and offline installs must
# fail on an empty cache but succeed on the warm cache - proving the warm run's
# packages really come from the cache.
set -eu

blank_npmrc=$(mktemp "${TMPDIR:-/tmp}/fm-npmrc.XXXXXX")
OUT=${1:-}
: > "$blank_npmrc"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-npmcache.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
export npm_config_userconfig="$blank_npmrc"
export npm_config_cache="$LAB/npm-cache"
export npm_config_update_notifier=false

PKGS="tasks-axi @earendil-works/pi-coding-agent"
tgz_fetches() { grep -cE 'registry\.npmjs\.org/.+/-/.+\.tgz' "$1" || true; }

echo "== 1. cold run: empty cache, plain 'npm install -g' (today's uncached flow / cache miss) =="
export npm_config_prefix="$LAB/prefix-cold"
t0=$(date +%s)
npm install -g $PKGS --loglevel=http >"$LAB/cold.log" 2>&1 || { echo "cold install FAILED"; tail -20 "$LAB/cold.log"; exit 1; }
t1=$(date +%s)
echo "cold: exit=0 wall=$((t1 - t0))s tarball-fetch-lines=$(tgz_fetches "$LAB/cold.log")"
"$(npm prefix -g)/bin/tasks-axi" --version >/dev/null 2>&1 && echo "cold: tasks-axi runs from the fresh global install"
echo

echo "== 2. warm run: same cache, FRESH prefix, same plain command (what a cache-hit CI run does) =="
unset npm_config_prefix
export npm_config_prefix="$LAB/prefix-warm"
t0=$(date +%s)
npm install -g $PKGS --loglevel=http >"$LAB/warm.log" 2>&1 || { echo "warm install FAILED"; tail -20 "$LAB/warm.log"; exit 1; }
t1=$(date +%s)
echo "warm: exit=0 wall=$((t1 - t0))s tarball-fetch-lines=$(tgz_fetches "$LAB/warm.log")"
grep -E 'registry\.npmjs\.org/.+/-/.+\.tgz' "$LAB/warm.log" | sed -n '1,5p' || true
"$(npm prefix -g)/bin/tasks-axi" --version >/dev/null 2>&1 && echo "warm: tasks-axi runs from the warm-cache global install"
echo

echo "== 3. adversarial: --offline with the WARM cache must succeed (zero network) =="
unset npm_config_prefix
export npm_config_prefix="$LAB/prefix-offline-warm"
if npm install -g $PKGS --offline >"$LAB/offline-warm.log" 2>&1; then
  echo "offline+warm cache: exit=0 - the cache fully holds what the installs need"
else
  echo "offline+warm cache: FAILED"; tail -10 "$LAB/offline-warm.log"; exit 1
fi
echo

echo "== 4. adversarial: --offline with an EMPTY cache must FAIL (proves #3 came from the cache) =="
export npm_config_cache="$LAB/empty-cache"
unset npm_config_prefix
export npm_config_prefix="$LAB/prefix-offline-cold"
if npm install -g $PKGS --offline >"$LAB/offline-cold.log" 2>&1; then
  echo "offline+empty cache: unexpectedly succeeded - warm proof invalid"; exit 1
else
  echo "offline+empty cache: exit=$? as expected (ENOTCACHED / cache miss needs network)"
  grep -m1 -E 'ENOTCACHED|cache miss|not cached' "$LAB/offline-cold.log" || sed -n '1,5p' "$LAB/offline-cold.log"
fi
echo

echo "== summary =="
echo "cold(warm-miss) tarball fetches: $(tgz_fetches "$LAB/cold.log")"
echo "warm        tarball fetches: $(tgz_fetches "$LAB/warm.log")"
echo "warm-run tarball lines served FROM CACHE (no network): $(grep -cE 'registry\.npmjs\.org/.+/-/.+\.tgz.*\(cache hit\)' "$LAB/warm.log" || true)"
echo "warm-run tarball lines fetched from NETWORK:          $(grep -E 'registry\.npmjs\.org/.+/-/.+\.tgz' "$LAB/warm.log" | grep -vcE '\(cache hit\)' || true)"
if [ -n "${OUT:-}" ]; then
  grep -E 'registry\.npmjs\.org/.+/-/.+\.tgz' "$LAB/warm.log" | head -30 > "$OUT/03-warm-tarball-lines.txt"
  grep -E 'registry\.npmjs\.org/.+/-/.+\.tgz' "$LAB/cold.log" | head -10 > "$OUT/03-cold-tarball-lines.txt"
fi
echo "PASS: warm cache serves the global installs without fresh tarball downloads; miss behaves like today"

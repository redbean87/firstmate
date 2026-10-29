set -u
# Real-forge drive: the REAL readiness seam, the REAL gh binary, the operator's
# existing gh login, and real GitHub pull requests. Every call is read-only.
ROOT=/Users/cortezashley/.no-mistakes/worktrees/ea4b1a4b43db/01M63XJHWJ0SFD2S3J7FQ4B453
SEAM=$ROOT/fork/pr-green/extension/readiness.mjs
WORK=/private/tmp/fm-live-pr-green/realf
rm -rf "$WORK"; mkdir -p "$WORK/home/state" "$WORK/home/config"
echo "gh: $(command -v gh) ($(gh --version | head -1))"
echo

run() {  # <label> <entry-id> <pr-url> [recorded-head]
  local label=$1 id=$2 url=$3 head=${4:-}
  [ -n "$head" ] || head=$(gh pr view "$url" --json headRefOid -q .headRefOid)
  jq -cn --arg id "$id" --arg head "$head" --arg url "$url" \
    '{id:$id,mode:"no-mistakes",yolo:"on",kind:"ship",pr:$url,host:"github.com",
      owner:($url|capture("https://github.com/(?<o>[^/]+)/").o),
      repo:($url|capture("/(?<r>[^/]+)/pull/").r),number:($url|capture("pull/(?<n>[0-9]+)").n),
      head:$head,meta:"/fixture/state/none.meta"}' > "$WORK/entry.json"
  jq -cn --arg home "$WORK/home" '{home:$home,stateDir:($home+"/state"),configDir:($home+"/config"),now:0,evaluateCount:1}' > "$WORK/ctx.json"
  cat > "$WORK/driver.mjs" <<'JS'
import fs from "node:fs";
const { decideWake } = await import(process.argv[2]);
const entry = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const ctx = JSON.parse(fs.readFileSync(process.argv[4], "utf8"));
ctx.log = (line) => process.stderr.write(`${line}\n`);
process.stdout.write(`${JSON.stringify(decideWake(entry, ctx))}\n`);
JS
  printf '%-42s ' "$label"
  node "$WORK/driver.mjs" "$SEAM" "$WORK/entry.json" "$WORK/ctx.json" 2>"$WORK/seam.err" \
    | jq -r 'if . == null then "SILENT" else .advisory end'
  sed 's/^/    /' "$WORK/seam.err"
}

echo "=== real GitHub, real gh, real seam ====================================="
run "open, non-draft, green, no required check" jq-3699 https://github.com/jqlang/jq/pull/3699
run "open, green, 3 required checks reported"    cli-14858 https://github.com/cli/cli/pull/14858
run "open, green rollup, required never reported" cli-14867 https://github.com/cli/cli/pull/14867
run "open + green but recorded head is stale"    cli-stale https://github.com/cli/cli/pull/14858 2222222222222222222222222222222222222222
run "already merged pull request"                cli-merged https://github.com/cli/cli/pull/14854
echo
echo "=== the real forge's own answers behind those verdicts =================="
printf 'jq-3699   branch '; gh api repos/jqlang/jq/branches/master -q '{protected}' 2>/dev/null | tr -d '\n'; printf '  rulesets '; gh api --paginate --slurp repos/jqlang/jq/rules/branches/master 2>/dev/null | jq -c 'map(map(.type))'
printf 'cli-14858 branch '; gh api repos/cli/cli/branches/trunk -q '{protected, required: .protection.required_status_checks.contexts}' 2>/dev/null | tr -d '\n'; printf '  rulesets '; gh api --paginate --slurp repos/cli/cli/rules/branches/trunk 2>/dev/null | jq -c 'map(map({type, required: .parameters.required_status_checks}))'
printf 'cli-14867 reported check names '; gh pr view https://github.com/cli/cli/pull/14867 --json statusCheckRollup -q '[.statusCheckRollup[]|.name]|join(", ")' 2>/dev/null
rm -rf "$WORK"

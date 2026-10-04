#!/usr/bin/env bash
# Scenario 2: execute the workflow's own "Record npm cache key inputs" step
# script (extracted from the YAML, not retyped) and assert its observable
# outputs: major = the running node's major, day = today's UTC date.
# Scenario 3: typed semantic model of the cache contract - single OS+Node+day
# exact key, restore-keys prefix that matches older day keys, ~/.npm path, and
# every npm global install in ci.yml runs after its job's cache step.
set -eu
ROOT="${1:?usage: 02-cache-key-and-model.sh <repo-root>}"
OUT="${2:?usage: 02-cache-key-and-model.sh <repo-root> <evidence-dir>}"
cd "$ROOT"

echo "== execute the record-key step script extracted from ci.yml =="
GITHUB_OUTPUT="$(mktemp "${TMPDIR:-/tmp}/fm-ghout.XXXXXX")"
export GITHUB_OUTPUT
STEP_SCRIPT=$(ruby -ryaml -e '
doc = YAML.load_file(".github/workflows/ci.yml")
step = doc.fetch("jobs").fetch("tests-portable-parallel-1").fetch("steps").find { |s| s["id"] == "npm-cache-node" }
abort "record-key step missing" unless step
print step.fetch("run")
')
printf '%s\n' "$STEP_SCRIPT" | bash
echo "--- GITHUB_OUTPUT written by the step ---"
cat "$GITHUB_OUTPUT"
major=$(sed -n 's/^major=//p' "$GITHUB_OUTPUT")
day=$(sed -n 's/^day=//p' "$GITHUB_OUTPUT")
[ "$major" = "$(node -p 'process.versions.node.split(".")[0]')" ] \
  || { echo "FAIL: major=$major, expected $(node -p 'process.versions.node.split(".")[0]')"; exit 1; }
[ "$day" = "$(date -u +%Y%m%d)" ] \
  || { echo "FAIL: day=$day, expected $(date -u +%Y%m%d)"; exit 1; }
case "$day" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
  *) echo "FAIL: day=$day is not YYYYMMDD"; exit 1 ;;
esac
echo "PASS: step emits major=$major day=$day"
echo

echo "== semantic model of the cache contract across every job =="
ruby -ryaml - <<'RUBY'
require "date"
doc = YAML.load_file(".github/workflows/ci.yml")
os = "Linux"  # runner.os value for the Linux jobs; macOS checked separately
day = Date.today.strftime("%Y%m%d")
yesterday = (Date.today - 1).strftime("%Y%m%d")
major = `node -p 'process.versions.node.split(".")[0]'`.strip

jobs = doc.fetch("jobs")
cached_jobs = jobs.select { |_n, j| j.fetch("steps").any? { |s| s["uses"].to_s.start_with?("actions/cache") } }
abort "expected 4 cached jobs, got #{cached_jobs.keys.inspect}" unless cached_jobs.size == 4

# Collect every npm global install in the whole workflow, with its job + index.
installs = []
jobs.each do |name, job|
  job.fetch("steps").each_with_index do |s, i|
    installs << [name, i, s["name"]] if s["run"].to_s.include?("npm install -g")
  end
end
abort "expected 6 npm global installs in ci.yml, got #{installs.size}" unless installs.size == 6

installs.each do |job_name, idx, step_name|
  job = jobs.fetch(job_name)
  steps = job.fetch("steps")
  cache = steps.find { |s| s["uses"].to_s.start_with?("actions/cache") }
  abort "#{job_name}/#{step_name}: no cache step in job" unless cache
  cache_idx = steps.index(cache)
  abort "#{job_name}/#{step_name}: cache step (#{cache_idx}) does not precede install (#{idx})" unless cache_idx < idx
  puts "covered: #{job_name} / #{step_name} after '#{cache["name"]}'"
end

# One identical key template everywhere: npm-global-<os>-node<major>-<day>,
# with a restore-keys prefix that matches older day keys (daily rotation).
templates = cached_jobs.map do |name, job|
  cache = job.fetch("steps").find { |s| s["uses"].to_s.start_with?("actions/cache") }
  abort "#{name}: cache path must be ~/.npm" unless cache.fetch("with").fetch("path") == "~/.npm"
  key = cache.fetch("with").fetch("key")
  restores = cache.fetch("with").fetch("restore-keys").split("\n").map(&:strip)
  key
end
abort "cache key templates differ across jobs:\n#{templates.uniq.join("\n")}" unless templates.uniq.size == 1

tmpl = templates.first.sub("${{ runner.os }}", os)
  .sub("${{ steps.npm-cache-node.outputs.major }}", major)
  .sub("${{ steps.npm-cache-node.outputs.day }}", day)
expected = "npm-global-#{os}-node#{major}-#{day}"
abort "key template renders #{tmpl.inspect}, expected #{expected.inspect}" unless tmpl == expected
puts "key template (single, identical in all 4 jobs): npm-global-<os>-node<major>-<day> -> #{expected}"

cache0 = cached_jobs.first[1].fetch("steps").find { |s| s["uses"].to_s.start_with?("actions/cache") }
prefix_tmpl = cache0.fetch("with").fetch("restore-keys").split("\n").map(&:strip).first
abort "expected exactly one restore-key" unless cache0.fetch("with").fetch("restore-keys").split("\n").map(&:strip).size == 1
prefix = prefix_tmpl.sub("${{ runner.os }}", os).sub("${{ steps.npm-cache-node.outputs.major }}", major)
expected_prefix = "npm-global-#{os}-node#{major}-"
abort "restore prefix #{prefix.inspect} != #{expected_prefix.inspect}" unless prefix == expected_prefix

# actions/cache restore-keys are starts-with matches: yesterday's exact key
# must be prefix-matched after the day rotates, and today != yesterday.
ykey = "npm-global-#{os}-node#{major}-#{yesterday}"
abort "restore prefix does not match yesterday's key #{ykey}" unless ykey.start_with?(prefix)
abort "day does not rotate: today #{day} == yesterday #{yesterday}" if day == yesterday
# Adversarial: a different Node major or OS must NOT prefix-match (no cross-job
# false hits across runners).
abort "prefix must not leak across OS" if "npm-global-Other-node#{major}-#{day}".start_with?(prefix)
abort "prefix must not leak across Node majors" if "npm-global-#{os}-node#{major.to_i + 1}-#{day}".start_with?(prefix)
puts "rotation: #{ykey} prefix-matches '#{prefix}'; cross-OS / cross-major keys do not"
puts "PASS: semantic cache model holds"
RUBY

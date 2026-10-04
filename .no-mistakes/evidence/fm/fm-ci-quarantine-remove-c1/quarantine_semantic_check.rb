#!/usr/bin/env ruby
# frozen_string_literal: true
# Semantic check of the quarantine-removal change on .github/workflows/ci.yml.
#
# Parses the base and target workflow YAML into models, resolves the
# continue-on-error GitHub expression against the matrix context for every
# serial shard, derives the workflow conclusion GitHub would compute when a
# shard job fails, and deep-compares the two models so the removal provably
# changes nothing except that one key. No substring matching.
require 'yaml'

BASE_REV  = '06f799faf79bae7e169a1b1646b37527a0fedf0b'
TARGET_REV = 'fe2bf66cefb547cd8c0c73a1d6f1b41255086540'

def load_rev(rev)
  yaml = IO.popen(['git', 'show', "#{rev}:.github/workflows/ci.yml"], 'rb', &:read)
  raise "git show failed for #{rev}" unless $?.success?
  YAML.safe_load(yaml, aliases: true)
end

# Resolve the handful of expression forms this workflow may use for
# continue-on-error: literal booleans, absence, and `a || b` comparisons
# of matrix.shard against integers. Returns true/false.
def resolve_continue_on_error(raw, shard)
  case raw
  when nil then false
  when true, false then raw
  when String
    expr = raw.gsub(/\$\{\{|\}\}/, '').strip
    # split on ||, each operand: `matrix.shard == N` or bare true/false
    expr.split('||').any? do |operand|
      operand = operand.strip
      if operand =~ /\Amatrix\.shard\s*==\s*(\d+)\z/
        shard == Regexp.last_match(1).to_i
      elsif operand == 'true'
        true
      elsif operand == 'false'
        false
      else
        raise "unresolvable continue-on-error operand: #{operand.inspect}"
      end
    end
  else
    raise "unexpected continue-on-error value: #{raw.inspect}"
  end
end

# GitHub semantics: with fail-fast false, every shard job runs; the run fails
# if any shard job conclusion is failure. A job whose continue-on-error is
# true reports 'success' at the run level despite a failed job.
def run_conclusion(shard_jobs)
  shard_jobs.any? { |shard, failed, coe| failed && !coe } ? 'failure' : 'success'
end

base = load_rev(BASE_REV)
target = load_rev(TARGET_REV)

job_key = 'tests-portable-serial'
base_job = base.fetch('jobs').fetch(job_key)
target_job = target.fetch('jobs').fetch(job_key)
shards = target_job.fetch('strategy').fetch('matrix').fetch('shard')
raise "unexpected shard matrix: #{shards.inspect}" unless shards == [1, 2, 3, 4, 5, 6, 7, 8, 9]

puts "== continue-on-error per serial shard job (resolved against matrix context) =="
[['base ' + BASE_REV[0, 8], base_job], ['target ' + TARGET_REV[0, 8], target_job]].each do |label, job|
  shards.each do |shard|
    coe = resolve_continue_on_error(job['continue-on-error'], shard)
    puts format('%s shard %d: continue-on-error=%-5s failed-job=>run conclusion: %s',
                label, shard, coe, coe ? 'success (NON-BLOCKING)' : 'failure (BLOCKING)')
  end
end

# The adversarial scenario: simulate a failing shard 5 and shard 6 job.
puts
puts "== simulated failing shard 5 and 6 jobs =="
[['base', base_job], ['target', target_job]].each do |label, job|
  jobs = shards.map { |s| [s, [5, 6].include?(s), resolve_continue_on_error(job['continue-on-error'], s)] }
  conclusion = run_conclusion(jobs)
  puts "#{label}: run conclusion with shards 5+6 failed = #{conclusion}"
  if label == 'base'
    raise 'expected base to be non-blocking' unless conclusion == 'success'
  else
    raise 'target must block on failed shards 5+6' unless conclusion == 'failure'
  end
end

# "and nothing else": deep-compare the two workflow models.
def deep_diff(a, b, path = '')
  diffs = []
  if a.is_a?(Hash) && b.is_a?(Hash)
    (a.keys | b.keys).sort_by(&:to_s).each do |k|
      if !a.key?(k)
        diffs << "#{path}/#{k}: added (#{b[k].inspect})"
      elsif !b.key?(k)
        diffs << "#{path}/#{k}: removed (was #{a[k].inspect})"
      else
        diffs.concat(deep_diff(a[k], b[k], "#{path}/#{k}"))
      end
    end
  elsif a.is_a?(Array) && b.is_a?(Array)
    if a.length != b.length
      diffs << "#{path}: array length #{a.length} -> #{b.length}"
    else
      a.each_with_index { |v, i| diffs.concat(deep_diff(v, b[i], "#{path}[#{i}]")) }
    end
  elsif a != b
    diffs << "#{path}: #{a.inspect} -> #{b.inspect}"
  end
  diffs
end

puts
puts "== semantic diff base -> target =="
diffs = deep_diff(base, target)
diffs.each { |d| puts d }
# assert the exact diff shape:
unless diffs.length == 1 && diffs.first =~ %r{\A/jobs/tests-portable-serial/continue-on-error: removed \(was "\$\{\{ matrix\.shard == 5 \|\| matrix\.shard == 6 \}\}"\)\z}
  raise "diff must be exactly the removed continue-on-error key, got: #{diffs.inspect}"
end
puts
puts 'PASS: the only semantic change is removal of the shard 5/6 continue-on-error quarantine;'
puts '      all nine serial shards are now unconditionally blocking.'

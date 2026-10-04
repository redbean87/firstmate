#!/usr/bin/env ruby
# Semantic check of .github/workflows/ci.yml's tests-portable-serial job:
# parse the workflow as YAML, resolve the job's continue-on-error expression
# against each matrix shard, and report which shard failures GitHub would
# tolerate. Usage: ruby evaluate-quarantine.rb <path-to-ci.yml>
require 'yaml'

doc = YAML.load_file(ARGV[0])
job = doc.fetch('jobs').fetch('tests-portable-serial')
matrix = job.fetch('strategy').fetch('matrix').fetch('shard')
coe_raw = job['continue-on-error']

# Minimal resolver for the expression constructs used here: numeric literal
# comparisons and `||`. Raises on anything else so it fails closed.
def resolve(expr, shard)
  expr = expr.strip
  expr = expr.sub(/\A\$\{\{/, '').sub(/\}\}\z/, '')
  if expr.include?('||')
    return expr.split('||').map { |t| resolve(t, shard) }.any?
  end
  if (m = expr.match(/\Amatrix\.shard\s*==\s*(\d+)\z/))
    return shard == m[1].to_i
  end
  raise "unresolvable construct: #{expr.inspect}"
end

puts "job: #{job['name']}"
puts "steps that still execute per shard: #{job.fetch('steps').map { |s| s['name'] || s['uses'] }.inspect}"
puts "matrix shards (visible check names): #{matrix.map { |s| "Behavior portable serial #{s}" }.join(', ')}"
puts "continue-on-error raw: #{coe_raw.inspect}"
puts ''
puts 'shard | continue-on-error (failure tolerated?)'
tolerated = []
matrix.each do |shard|
  v = coe_raw.nil? ? false : resolve(coe_raw, shard)
  tolerated << shard if v
  puts "#{shard}    | #{v}"
end
puts ''
puts "tolerated shards: #{tolerated.inspect}"

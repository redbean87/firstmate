#!/usr/bin/env ruby
# Evaluate ci.yml's job-level `if` conditions for a given detect-changes result
# and outputs, and print the resulting job set (RUN/SKIP) the way GitHub's job
# scheduler would decide it. Conditions are parsed structurally from the YAML;
# any condition shape outside this workflow's gate family raises, so an unknown
# `if` can never silently read as RUN.
#
# Usage: job-set-eval.rb <result> <code> <shell>   (result: success|failure|...)
require "yaml"

wf = YAML.load_file(ARGV[0])
result, code, shell = ARGV[1], ARGV[2], ARGV[3]

signals = {
  "needs.detect-changes.result" => result,
  "needs.detect-changes.outputs.code" => code,
  "needs.detect-changes.outputs.shell" => shell,
}

evaluate = lambda do |cond|
  cond = cond.strip
  cond = Regexp.last_match(1).strip if cond =~ /\A\$\{\{(.*)\}\}\z/m
  return [nil, "unconditional"] if cond.empty?
  body = cond.sub(/\A(!cancelled\(\)|always\(\))\s*&&\s*/, "")
  cancelled_guard = cond.start_with?("!cancelled()")
  raise "unexpected condition shape: #{cond}" unless body.start_with?("(") && body.end_with?(")")
  inner = body[1..-2]
  ops = inner.split("||").map(&:strip)
  evaluated = ops.map do |op|
    if op =~ /\A(needs\.detect-changes\.(?:result|outputs\.\w+)) (!=|==) '([^']*)'\z/
      lhs, opr, rhs = signals[$1], $2, $3
      raise "signal #{$1} unset" if lhs.nil?
      (opr == "==" ? lhs == rhs : lhs != rhs)
    else
      raise "unexpected operand: #{op}"
    end
  end
  # cancelled_guard: GitHub treats !cancelled() as true for a non-cancelled job.
  [evaluated.any?, cancelled_guard ? "!cancelled() && (gate)" : "always() && (gate)"]
end

printf("%-32s %-8s %s\n", "job id", "decision", "condition family")
jobs = wf.fetch("jobs")
jobs.each do |name, job|
  run, family = evaluate.call(job["if"].to_s)
  decision = run.nil? || run ? "RUN" : "SKIP"
  printf("%-32s %-8s %s\n", name, decision, family)
end

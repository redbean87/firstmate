#!/usr/bin/env bash
# Shared authoritative GitHub required-check verdict, owned here so the merge
# gate (bin/fm-pr-merge.sh) and the PR-readiness path judge one pull request's
# checks with exactly one implementation instead of two that can drift.
#
# A sourcing caller supplies what the reads need and this file re-reads none of
# it: PR_OWNER and PR_REPO from bin/fm-pr-lib.sh's fm_pr_url_parse, the caller's
# exported GH_HOST, and gh plus jq on PATH. Nothing here parses a URL, reads
# task state, decides merge authority, or writes to stdout, so a readiness
# caller can treat every failure as silence.
#
# github_checks_not_green owns what makes a reported check green.
# github_read_required_contexts owns where the required set comes from and how
# an unreadable source is reported. github_required_checks_missing owns which
# requirements have not reported, and github_read_required_producers owns the
# producer app binding those requirements are matched against. A check that
# never reported is absent from the rollup rather than red, which is why the
# required set cannot be derived from the rollup.
#
# fm_pr_github_check_verdict composes those reads into one verdict at one head:
#
#   green      every input the verdict needs was read, and nothing unwaived is
#              red or unreported
#   blocked    the inputs were read, and a check or requirement refuses
#   unreadable the pull request payload or its rollup could not be read at all
#
# It returns 0 only for green. Its exit status is therefore the readiness
# predicate: a caller that passes no waivers gets readiness, and one that
# passes the merge gate's attended waiver gets that gate's refusal detail from
# the same code. Incomplete input is never green, because an unreadable
# required-context source and a rollup that will not parse both leave the
# verdict blocked instead of falling back to an empty requirement set.

# Percent-encode one path segment for a GitHub API path.
github_urlencode_path_segment() {
  local LC_ALL=C input=$1 encoded='' char octet hex
  while [ -n "$input" ]; do
    char=${input%"${input#?}"}
    input=${input#?}
    case "$char" in
      [-._~a-zA-Z0-9]) encoded=$encoded$char ;;
      *)
        printf -v octet '%d' "'$char"
        [ "$octet" -ge 0 ] || octet=$((octet + 256))
        printf -v hex '%02X' "$octet"
        encoded=$encoded%$hex
        ;;
    esac
  done
  printf '%s' "$encoded"
}

# Whether a failed branch-rules read (the gh stderr given) is GitHub's
# plan-gated 403 ("Upgrade to GitHub Pro or make this repository public"),
# which means the repository's plan cannot expose branch rules at all, on
# GitHub or GitHub Enterprise Server - not that this script failed to read
# them, and not that the token lacks a permission. Such a repository has no
# active ruleset rule of any kind. Any other failure (auth, rate limit,
# network, a 404, an unrelated 403) is not this and stays unreadable.
github_branch_rules_unavailable_on_plan() {
  case "$1" in
    *"Upgrade to GitHub Pro or make this repository public"*) return 0 ;;
  esac
  return 1
}

# Every GitHub check that is not green in the given live pull-request JSON, one
# name per line. An entry is green when it is a status context whose state is
# SUCCESS, or a check run that completed with SUCCESS, NEUTRAL, or SKIPPED (so
# a pending check is not green either). Exits nonzero when the rollup cannot be
# read, so a malformed answer is a failed read and never an empty red set.
#
# The rollup can hold several runs of one check name at the same head, because
# GitHub cancels a pull request's in-flight run when the base branch advances
# and re-triggers it; the cancelled run stays in the rollup beside the passing
# re-run. A check is therefore judged by its current run rather than by any run
# that a later one superseded, which is what makes this agree with GitHub's own
# CLEAN mergeStateStatus instead of refusing a pull request GitHub considers
# mergeable.
#
# Supersession applies only among check runs with the same reported name. A
# name is dropped from the red set only when every non-green run is COMPLETED,
# has a whole-second UTC startedAt, and started strictly before a green run.
# Status contexts are never grouped or superseded, and every non-green one is
# reported independently. A still-running, queued, undated, or tied check run
# stays red. A name whose runs are all green needs no timestamp, while a name
# with no green run stays red.
#
# The reported name is also what --allow-red matches. An unnamed check run is
# grouped alone and can neither supersede nor be superseded, because unrelated
# unnamed checks must not be treated as one.
github_checks_not_green() {
  local json=$1
  printf '%s' "$json" | jq -r '
    def settled_at:
      if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
      then . else null end;
    if (.statusCheckRollup | type) != "array" then error("no check rollup") else . end
    | [ .statusCheckRollup
        | to_entries[]
        | .key as $i
        | .value
        | if .__typename == "CheckRun" then
            {
              kind: "check_run",
              name: (.name // ""),
              completed: (.status == "COMPLETED"),
              ok: (.status == "COMPLETED" and (.conclusion == "SUCCESS" or .conclusion == "NEUTRAL" or .conclusion == "SKIPPED")),
              at: (.startedAt | settled_at)
            }
            | . + {group: (if .name == "" then ["", $i] else [.name, -1] end)}
          else
            {kind: "status_context", name: (.context // ""), ok: (.state == "SUCCESS")}
          end
      ]
    | . as $entries
    | (
        ($entries[]
          | select(.kind == "status_context" and (.ok | not))
          | .name
        ),
        ($entries
          | [.[] | select(.kind == "check_run")]
          | group_by(.group)[]
          | {
              name: .[0].name,
              reds: [.[] | select(.ok | not)],
              newest_green: ([.[] | select(.ok) | .at | select(. != null)] | max)
            }
          | select(
              (.reds | length) > 0
              and (
                .newest_green == null
                or any(.reds[]; (.completed | not) or .at == null)
                or ([.reds[] | .at] | max) >= .newest_green
              )
            )
          | .name
        )
      )
    | if . == "" then "(unnamed check)" else . end
  ' 2>/dev/null || return 1
}

FM_PR_GITHUB_REQUIRED=
FM_PR_GITHUB_REQUIRED_ERROR=
github_read_required_contexts() {
  local base=$1 branch_path branch_json rules_json classic='' ruleset='' api_err api_err_text
  FM_PR_GITHUB_REQUIRED='[]'
  FM_PR_GITHUB_REQUIRED_ERROR=
  branch_path=$(github_urlencode_path_segment "$base")

  if ! branch_json=$(gh api "repos/$PR_OWNER/$PR_REPO/branches/$branch_path" 2>/dev/null) \
    || [ -z "$branch_json" ] \
    || ! classic=$(printf '%s' "$branch_json" | jq -c '
      if type != "object" or (.protected | type) != "boolean" then
        error("branch payload is unreadable")
      elif .protected == false then
        empty
      elif (.protection.required_status_checks | type) != "object" then
        error("branch protection summary is unreadable")
      else
        .protection.required_status_checks
        | ((.checks // []) | if type == "array" then .[] else error("invalid checks") end
           | {context, app_id}),
          ((.contexts // []) | if type == "array" then .[] else error("invalid contexts") end
           | {context: ., app_id: null})
        | if (.context | type) == "string" and (.context | length) > 0
             and (.app_id == null or (.app_id | type) == "number")
          then . else error("invalid required check") end
        | if .app_id == -1 then .app_id = null else . end
      end' 2>/dev/null); then
    classic=''
    FM_PR_GITHUB_REQUIRED_ERROR="the branch protection summary for base branch $base could not be read"
  fi

  if ! api_err=$(mktemp "${TMPDIR:-/tmp}/fm-pr-merge-required-rules.XXXXXX"); then
    FM_PR_GITHUB_REQUIRED_ERROR="${FM_PR_GITHUB_REQUIRED_ERROR:+$FM_PR_GITHUB_REQUIRED_ERROR
}the branch rules for base branch $base could not be read"
  else
    if ! rules_json=$(gh api --paginate "repos/$PR_OWNER/$PR_REPO/rules/branches/$branch_path" 2>"$api_err"); then
      api_err_text=$(cat "$api_err" 2>/dev/null)
      if ! github_branch_rules_unavailable_on_plan "$api_err_text"; then
        FM_PR_GITHUB_REQUIRED_ERROR="${FM_PR_GITHUB_REQUIRED_ERROR:+$FM_PR_GITHUB_REQUIRED_ERROR
}the branch rules for base branch $base could not be read"
      fi
    elif [ -z "$rules_json" ] || ! ruleset=$(printf '%s' "$rules_json" | jq -c '
        if type != "array" then error("rules payload is unreadable") else .[] end
        | select(type != "object" or .type == "required_status_checks")
        | if type == "object" and (.parameters.required_status_checks | type) == "array"
          then .parameters.required_status_checks[] else error("invalid required check rule") end
        | if type == "object" and (.context | type) == "string" and (.context | length) > 0
             and (.integration_id == null or (.integration_id | type) == "number")
          then {context, app_id: .integration_id} else error("invalid required check rule") end
        | if .app_id == -1 then .app_id = null else . end' 2>/dev/null); then
      ruleset=''
      FM_PR_GITHUB_REQUIRED_ERROR="${FM_PR_GITHUB_REQUIRED_ERROR:+$FM_PR_GITHUB_REQUIRED_ERROR
}the branch rules for base branch $base could not be read"
    fi
    rm -f "$api_err"
  fi

  FM_PR_GITHUB_REQUIRED=$(printf '%s\n%s\n' "$classic" "$ruleset" | jq -sc '
    unique_by([.context, .app_id]) | group_by(.context)
    | map(if any(.[]; .app_id != null) then map(select(.app_id != null)) else . end) | add // []')
  [ -z "$FM_PR_GITHUB_REQUIRED_ERROR" ]
}

# Which required contexts have not reported at all in the given rollup. Prints
# one context name per line, so an absent requirement is reported apart from a
# red one, and exits nonzero when the rollup cannot be read.
github_required_checks_missing() {
  local json=$1 required=$2 producers=$3
  printf '%s' "$json" | jq -r --argjson required "$required" --argjson producers "$producers" '
    if (.statusCheckRollup | type) != "array" then error("no check rollup") else . end
    | .statusCheckRollup as $reported
    | $required
    | map(. as $requirement
      | select(any($reported[];
          if $requirement.app_id == null then
            (if .__typename == "CheckRun" then .name else .context end) == $requirement.context
          elif .__typename == "CheckRun" then
            .name == $requirement.context
            and any($producers[]; .name == $requirement.context and .app.id == $requirement.app_id)
          else
            .context == $requirement.context
          end) | not)
      | .context) | unique[]
  ' 2>/dev/null || return 1
}

# The producer apps behind app-bound required checks at one head, matching the
# producer read the merge gate has always made. Sets
# FM_PR_GITHUB_REQUIRED_PRODUCERS and returns nonzero when the requirement set
# is app-bound and that read fails, so a bound requirement is never satisfied
# through an unread read. A requirement set with no app binding needs no
# producer read at all.
FM_PR_GITHUB_REQUIRED_PRODUCERS='[]'
github_read_required_producers() {  # <head>
  local head=$1 runs
  FM_PR_GITHUB_REQUIRED_PRODUCERS='[]'
  if ! printf '%s' "$FM_PR_GITHUB_REQUIRED" | jq -e 'any(.[]; .app_id != null)' >/dev/null; then
    return 0
  fi
  if ! runs=$(gh api --paginate "repos/$PR_OWNER/$PR_REPO/commits/$head/check-runs" 2>/dev/null) \
    || [ -z "$runs" ]; then
    FM_PR_GITHUB_REQUIRED_PRODUCERS='[]'
    return 1
  fi
  if ! FM_PR_GITHUB_REQUIRED_PRODUCERS=$(printf '%s' "$runs" | jq -sc --arg head "$head" '
      [ .[] | if (.check_runs | type) == "array" then .check_runs[] else error("invalid check runs") end
        | if (.name | type) == "string" and (.app.id | type) == "number" and .head_sha == $head
          then . else error("invalid check producer") end ]' 2>/dev/null); then
    FM_PR_GITHUB_REQUIRED_PRODUCERS='[]'
    return 1
  fi
  return 0
}

# The one verdict both callers use. Args: <pull-request-json> <base> <head>,
# then optionally --allow-red <name> and --allow-missing <name> exactly as the
# merge gate's attended waivers parse them; a readiness caller passes neither.
# Every output below is reset on entry, so a failed call never leaves a
# previous verdict readable.
#
# FM_PR_GITHUB_VERDICT_LINES holds the merge gate's refusal detail lines in the
# order it has always reported them, so this helper owns the wording of a
# check refusal. The two _LIST values are the same red and unreported names
# joined for its summary lines.
FM_PR_GITHUB_VERDICT_STATUS=unreadable
FM_PR_GITHUB_VERDICT_RED=
FM_PR_GITHUB_VERDICT_RED_LIST=
FM_PR_GITHUB_VERDICT_UNREPORTED=
FM_PR_GITHUB_VERDICT_UNREPORTED_LIST=
FM_PR_GITHUB_VERDICT_LINES=
FM_PR_GITHUB_VERDICT_INCOMPLETE=false
fm_pr_github_check_verdict() {  # <json> <base> <head> [--allow-red <name>] [--allow-missing <name>]
  local json=$1 base=$2 head=$3
  local waived_red='' waived_missing='' json_head=''
  local red='' missing='' name
  local red_lines='' required_lines='' incomplete=false

  FM_PR_GITHUB_VERDICT_STATUS=unreadable
  FM_PR_GITHUB_VERDICT_RED=
  FM_PR_GITHUB_VERDICT_RED_LIST=
  FM_PR_GITHUB_VERDICT_UNREPORTED=
  FM_PR_GITHUB_VERDICT_UNREPORTED_LIST=
  FM_PR_GITHUB_VERDICT_LINES=
  FM_PR_GITHUB_VERDICT_INCOMPLETE=false

  shift 3
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --allow-red|--allow-missing)
        [ "$#" -ge 2 ] || return 1
        if [ "$1" = --allow-red ]; then waived_red=$2; else waived_missing=$2; fi
        shift 2
        ;;
      *) return 1 ;;
    esac
  done

  # Bind the verdict to the head it was computed at: a payload read at some
  # other head proves nothing about this one.
  if ! json_head=$(printf '%s' "$json" | jq -r '
      if type == "object" then (.headRefOid // "") | tostring
      else error("pull request payload is not an object") end' 2>/dev/null); then
    return 1
  fi
  if [ -z "$head" ] || [ "$json_head" != "$head" ]; then
    return 1
  fi

  if ! red=$(github_checks_not_green "$json"); then
    return 1
  fi

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ -n "$waived_red" ] && [ "$waived_red" = "$name" ]; then
      continue
    fi
    red_lines="$red_lines  - check '$name' is not green
"
    FM_PR_GITHUB_VERDICT_RED="${FM_PR_GITHUB_VERDICT_RED:+$FM_PR_GITHUB_VERDICT_RED
}$name"
    FM_PR_GITHUB_VERDICT_RED_LIST="${FM_PR_GITHUB_VERDICT_RED_LIST:+$FM_PR_GITHUB_VERDICT_RED_LIST, }$name"
  done <<EOF
$red
EOF

  # A required source that cannot be read is its own refusal: the requirements
  # it may have held cannot be ruled out, so it leaves the verdict blocked even
  # when the sources that did read are green. Requirements a readable source
  # did supply still get checked below.
  if ! github_read_required_contexts "$base"; then
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      required_lines="$required_lines  - $name, so a required check that has not reported cannot be ruled out
"
      incomplete=true
    done <<EOF
$FM_PR_GITHUB_REQUIRED_ERROR
EOF
  fi

  if ! github_read_required_producers "$head"; then
    required_lines="$required_lines  - required check producers at head $head could not be read
"
    incomplete=true
  fi

  if ! missing=$(github_required_checks_missing "$json" "$FM_PR_GITHUB_REQUIRED" "$FM_PR_GITHUB_REQUIRED_PRODUCERS"); then
    required_lines="$required_lines  - the GitHub pull request check rollup could not be read
"
    incomplete=true
    missing=''
  fi

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ -n "$waived_missing" ] && [ "$waived_missing" = "$name" ]; then
      continue
    fi
    required_lines="$required_lines  - required check '$name' has not reported at head $head
"
    FM_PR_GITHUB_VERDICT_UNREPORTED="${FM_PR_GITHUB_VERDICT_UNREPORTED:+$FM_PR_GITHUB_VERDICT_UNREPORTED
}$name"
    FM_PR_GITHUB_VERDICT_UNREPORTED_LIST="${FM_PR_GITHUB_VERDICT_UNREPORTED_LIST:+$FM_PR_GITHUB_VERDICT_UNREPORTED_LIST, }$name"
  done <<EOF
$missing
EOF

  FM_PR_GITHUB_VERDICT_LINES="$red_lines$required_lines"
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  FM_PR_GITHUB_VERDICT_INCOMPLETE=$incomplete
  if [ -z "$FM_PR_GITHUB_VERDICT_LINES" ] && [ "$incomplete" = false ]; then
    FM_PR_GITHUB_VERDICT_STATUS=green
    return 0
  fi
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  FM_PR_GITHUB_VERDICT_STATUS=blocked
  return 1
}

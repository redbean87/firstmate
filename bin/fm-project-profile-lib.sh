#!/usr/bin/env bash
# fm-project-profile-lib.sh - the single owner of the deterministic
# project-to-worker-profile binding for crewmate and scout dispatch.
#
# docs/configuration.md "Crew dispatch profiles" owns the operator-facing
# contract and the schema; this library owns the mechanical lookup both
# launch paths enforce in code.
#
# The mapping is exact-match on project name and free of natural-language
# matching, so it cannot be skipped or guessed. The effective home's
# config/crew-dispatch.json may carry two deterministic keys beside rules:
#   projects: an object mapping an exact project name to one profile object.
#   projectDefault: one profile object for every other project.
# A profile object carries harness (required), model (optional), and effort
# (optional); provider and floor are inert here and belong to typed
# resolution. When a project has a pin, the launch must name that pin's
# harness, and when the pin declares a model the launch must name that model
# exactly; a raw launch command never satisfies a pin. There is no per-task
# override: a project that needs a different worker class is an explicit
# project-policy change to this mapping.
#
# Secondmate spawns are exempt and never consult this library.
#
# Usage:
#   fm_project_profile_for <project-name> <config-dir>
#     Prints "harness<TAB>model<TAB>effort" for the pin that governs the
#     project, or nothing with exit 1 when no deterministic pin applies.
#     A malformed deterministic section refuses with one error on stderr and
#     exit 2, so a bad policy stops dispatch instead of launching around it.
# shellcheck disable=SC2034
FM_PROJECT_PROFILE_LIB=1

fm_project_profile_for() {
  local project=$1 config=${2:-} file pin_harness pin_model pin_effort
  [ -n "$project" ] || {
    echo "error: fm_project_profile_for requires a project name" >&2
    return 2
  }
  [ -n "$config" ] || return 1
  file="$config/crew-dispatch.json"
  [ -e "$file" ] || [ -L "$file" ] || return 1
  [ -f "$file" ] && [ -r "$file" ] || {
    echo "error: config/crew-dispatch.json is not a readable regular file: $file" >&2
    return 2
  }
  command -v jq >/dev/null 2>&1 || {
    echo "error: jq is required to read the project profile pin in $file" >&2
    return 2
  }
  if ! jq -e . "$file" >/dev/null 2>&1; then
    echo "error: config/crew-dispatch.json is malformed JSON: $file" >&2
    return 2
  fi
  if ! jq -e '
    (if has("projects") then (.projects | type) == "object" else true end)
    and (if has("projectDefault") then (.projectDefault | type) == "object" else true end)
    and ([(.projects // {})[]] | map(type == "object") | all)
    and ([(.projects // {})[]] | map(has("harness") and (.harness | type) == "string" and (.harness | length) > 0) | all)
  ' "$file" >/dev/null 2>&1; then
    echo "error: config/crew-dispatch.json has a malformed deterministic project mapping: projects must be an object of exact project names to profile objects with a non-empty harness, and projectDefault must be one profile object" >&2
    return 2
  fi
  if jq -e --arg p "$project" '.projects // {} | has($p)' "$file" >/dev/null 2>&1; then
    pin_harness=$(jq -r --arg p "$project" '.projects[$p].harness // empty' "$file")
    pin_model=$(jq -r --arg p "$project" '.projects[$p].model // empty' "$file")
    pin_effort=$(jq -r --arg p "$project" '.projects[$p].effort // empty' "$file")
  elif jq -e 'has("projectDefault")' "$file" >/dev/null 2>&1; then
    pin_harness=$(jq -r '.projectDefault.harness // empty' "$file")
    pin_model=$(jq -r '.projectDefault.model // empty' "$file")
    pin_effort=$(jq -r '.projectDefault.effort // empty' "$file")
  else
    return 1
  fi
  [ -n "$pin_harness" ] || {
    echo "error: config/crew-dispatch.json project pin for '$project' names no harness" >&2
    return 2
  }
  printf '%s\t%s\t%s\n' "$pin_harness" "${pin_model:-}" "${pin_effort:-}"
}

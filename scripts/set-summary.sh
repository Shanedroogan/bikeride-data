#!/usr/bin/env bash
# The data-build.yml step summary of a built set, as Markdown on stdout: the setId and the
# previous one, each artifact's xz size (built or carried), coverage days per system, each gate
# check's status and where flows came from. Every value comes from a manifest checked first, so
# nothing but names, digests, numbers and plain status words reaches the public log, and no key
# outside data/ and sources/ is ever named.
set -euo pipefail
SCRIPT=set-summary
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

if [[ ${1:-} == -h || ${1:-} == --help ]]; then
  echo "USAGE: scripts/set-summary.sh MANIFEST"
  exit 0
fi
[[ $# -eq 1 ]] || usage_error "one manifest"
need_tools jq
check_manifest "$1" "$1"

jq -r '
  "#### Set `\(.setId)`",
  "",
  "- previous set: " + (if .previousSetId then "`\(.previousSetId)`" else "none (a first set)" end),
  "- generated: \(.generatedAt), build day \(.buildDay)",
  "- gate: **\(.gate.status)**",
  "- flows: " + (if (.artifacts | has("flows")) | not then "none in this set"
                 elif (.carriedForward | index("flows")) then "carried from set `\(.previousSetId)`"
                 else "built in this run" end),
  "",
  "| artifact | xz bytes | |",
  "|---|---:|---|",
  (.carriedForward as $c | .artifacts | to_entries[]
    | .key as $name | "| \($name) | \(.value.bytes) | \(if ($c | index($name)) then "carried" else "built" end) |"),
  "",
  "| system | coverage days | last day | status |",
  "|---|---:|---|---|",
  (.systems | to_entries[] | (.value.last // "-") as $last
    | "| \(.key) | \(.value.days) | \(if ($last | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) then $last else "-" end) | \(.value.status) |"),
  "",
  "| gate check | status | warnings |",
  "|---|---|---:|",
  (.gate.checks[] | "| \(.name) | \(.status) | \(if (.warnings | type == "number") then .warnings else "-" end) |")
' "$1"

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
  cat <<'USAGE'
USAGE: scripts/set-summary.sh MANIFEST
       scripts/set-summary.sh --gate GATE_JSON

MANIFEST: the set's summary, as above. --gate: the trip-count change the gate accepted, from
reports/gate.json's acceptedTripCountChange (and each system's acceptedDates in the tripCounts
check); written by every gate run, so it is shown even when the gate failed. Only the five system
names and numbers are printed; nothing when the field is absent.
USAGE
  exit 0
fi
need_tools jq
if [[ ${1:-} == --gate ]]; then
  [[ $# -eq 2 ]] || usage_error "--gate takes one gate.json"
  jq -e 'type == "object"' "$2" >/dev/null 2>&1 || die "$2 is not a gate report"
  jq -r '
    def known: . as $s | ["subway", "bus", "lirr", "ferry", "path"] | index($s) != null;
    ((.checks // []) | map(select(.name == "tripCounts")) | first // {} | .metrics // {}) as $m
    | (.acceptedTripCountChange // null)
    | if type != "array" then empty
      else map(select(type == "string" and known)) as $systems
        | "- trip-count change accepted by the gate (gate.json): "
          + (if ($systems | length) == 0 then "none named"
             else $systems | map(. as $s | $m["\($s).acceptedDates"] as $n
               | if ($n | type) == "number" then "\($s) (\($n) dates beyond the limit)" else $s end) | join(", ")
             end)
      end' "$2"
  exit 0
fi
[[ $# -eq 1 ]] || usage_error "one manifest"
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

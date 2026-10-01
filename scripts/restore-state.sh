#!/usr/bin/env bash
# Restores what a publish run starts from: data-build.yml step 3, flows.yml and publish-local.sh.
# S0 stub: it parses its arguments and stops (exit 69); M4 lane Q writes the body, with tests
# against scripts/test/fake-aws. Every R2 call goes through scripts/r2.sh.
set -euo pipefail
SCRIPT=restore-state
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

usage() {
  cat <<'USAGE'
USAGE: scripts/restore-state.sh --job timetables|streets|flows --prev DIR --sources DIR --data DIR
                                [--today YYYYMMDD]

In order (docs/publish.md, "R2"):
  1. data/hold.json: while a hold is active, write the step summary and HOLD=1, and exit 0.
  2. data/manifest.json, data/heartbeat.json and the trip-count sidecar (data/trip-counts/<sha256>.json,
     by the manifest's tripCounts.sha256) into --prev as manifest.json, heartbeat.json and
     trip-counts.json. A 404 on the manifest is a first run (FIRST_RUN=1); a 403 or 5xx fails.
  3. sources/ records whose calendarEnd >= today - 1, and sources/aux/, into --sources (the
     builder's cache), each zip checked against its record's sha256; the list of what was
     restored goes to <prev>/sources-restored.txt for sync-sources.sh prune.
  4. timetables: the streets and stations blobs into --data, by the manifest's sha, checked by
     sha256, xz -dc and rawSha256.
  5. timetables and streets: fail if --data holds a flows.bin (flows never reaches the public runner).

Writes <prev>/state.env, one KEY=value per line with printf, no quotes: PREV_SET (the
manifest's setId, checked against ^[0-9a-f]{16}$; empty on a first run), FIRST_RUN and HOLD
(0 or 1). PREV_SET comes from R2, so readers take values with sed and check them; none sources
the file (data-build.yml's restore step holds the keys).

  --job NAME     timetables, streets (data-build.yml) or flows (flows.yml)
  --prev DIR     Where the previous set's documents go (the --previous of bikeride-data all)
  --sources DIR  The builder's source cache (the --sources of bikeride-data all)
  --data DIR     The data directory the run builds into (the --out of bikeride-data all)
  --today DATE   Build day (default today in New York)

Exit status: 0 restored (or a hold is active), 1 a failure, 64 usage, 69 not implemented yet.
USAGE
}

job='' prev='' sources='' data='' today=''
while [[ $# -gt 0 ]]; do
  case $1 in
    --job) need_value "$1" $#; job=$2; shift ;;
    --prev) need_value "$1" $#; prev=$2; shift ;;
    --sources) need_value "$1" $#; sources=$2; shift ;;
    --data) need_value "$1" $#; data=$2; shift ;;
    --today) need_value "$1" $#; check_day "$1" "$2"; today=$2; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage_error "unknown argument '$1'" ;;
  esac
  shift
done
case $job in timetables | streets | flows) ;; *) usage_error "--job needs timetables, streets or flows" ;; esac
[[ -n $prev && -n $sources && -n $data ]] || usage_error "--prev, --sources and --data are required"
: "$today"

# TODO(M4 lane Q): steps 1-5 above.
not_implemented

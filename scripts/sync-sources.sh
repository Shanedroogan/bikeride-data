#!/usr/bin/env bash
# The GTFS source archive mirrored in R2 under sources/ (docs/publish.md, "R2"): new records
# uploaded add-only on every real run, even a failing one, and deletions only after a publish.
# S0 stub: it parses its arguments and stops (exit 69); M4 lane Q writes the body, with tests
# against scripts/test/fake-aws. Every R2 call goes through scripts/r2.sh.
set -euo pipefail
SCRIPT=sync-sources
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

usage() {
  cat <<'USAGE'
USAGE: scripts/sync-sources.sh upload --sources DIR [--dry-run]
       scripts/sync-sources.sh prune  --sources DIR --restored FILE --today YYYYMMDD [--dry-run]

  upload  Add-only: PUT each archived version (sources/<feed>/<key>.zip and .json) and the aux
          files (sources/aux/subway-entrances.csv, borough-boundaries.geojson) not yet in R2.
          Never deletes. data-build.yml runs it with if: always() on real runs, so a version
          first seen by a run that then failed is kept.
  prune   After a successful publish only: delete the records the build pruned (in --restored,
          the list restore-state.sh wrote, and no longer in --sources) and those whose
          calendarEnd < today - 30.

  --sources DIR     The builder's source cache
  --restored FILE   What restore-state.sh restored (<prev>/sources-restored.txt)
  --today DATE      Build day
  --dry-run         Print the plan; write and delete nothing

Exit status: 0 done, 1 a failure, 64 usage, 69 not implemented yet.
USAGE
}

[[ $# -ge 1 ]] || usage_error "upload or prune?"
case $1 in
  -h | --help) usage; exit 0 ;;
  upload | prune) mode=$1; shift ;;
  *) usage_error "unknown command '$1'" ;;
esac
sources='' restored='' today='' dry_run=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --sources) need_value "$1" $#; sources=$2; shift ;;
    --restored) need_value "$1" $#; restored=$2; shift ;;
    --today) need_value "$1" $#; check_day "$1" "$2"; today=$2; shift ;;
    --dry-run) dry_run=1 ;;
    -h | --help) usage; exit 0 ;;
    *) usage_error "unknown argument '$1'" ;;
  esac
  shift
done
[[ -n $sources ]] || usage_error "--sources is required"
if [[ $mode == prune ]]; then
  [[ -n $restored && -n $today ]] || usage_error "prune needs --restored and --today"
fi
: "$dry_run"

# TODO(M4 lane Q): upload and prune above.
not_implemented

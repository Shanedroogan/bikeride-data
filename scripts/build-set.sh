#!/usr/bin/env bash
# The data-build.yml build: bikeride-data all with the arguments the job, the restored state and
# the dry-run flag call for, then the checks the public runner makes on what it built. It holds
# no R2 keys and makes no R2 call.
set -euo pipefail
SCRIPT=build-set
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

usage() {
  cat <<'USAGE'
USAGE: scripts/build-set.sh --job timetables|streets|streets-restored --prev DIR --data DIR --sources DIR
                            [--accept-trip-count-change LIST] [--dry-run]

Runs $BIKERIDE_DATA all --out <data> --sources <sources> --today <BUILD_DAY> and, by job:
  timetables        --job timetables --skip streets,stations,flows (streets and stations were
                    restored into <data>)
  streets           --job streets --skip streets,flows (the streets step already built
                    streets.bin into <data>; stations and the rest are rebuilt on it)
  streets-restored  as timetables: the streets fallback, after restore-state.sh --blobs-only
On a real run, or any run with a previous set: --previous <prev>/manifest.json --require-flows,
so flows is carried and a set without it fails. A first run (FIRST_RUN=1 in <prev>/state.env)
is built only with --dry-run, without --previous and --require-flows, and skips only flows (and
streets when the streets step built it): it proves the build on an empty bucket and publishes
nothing. A real first run is refused: the first set is published from the Mac.
Then: no flows.bin in <data>, and no "built without entrances" warning in
<data>/../reports/timetables.json.

  --job NAME                       As above
  --prev DIR                       What restore-state.sh wrote
  --data DIR                       The data directory (the --out of bikeride-data all)
  --sources DIR                    The source cache
  --accept-trip-count-change LIST  Passed to the gate (systems, comma-separated)
  --dry-run                        This run publishes nothing

Exit status: 0 built, 1 a failure, 64 usage; else the status of bikeride-data all.
USAGE
}

job='' prev='' data='' sources='' accept='' dry_run=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --job) need_value "$1" $#; job=$2; shift ;;
    --prev) need_value "$1" $#; prev=$2; shift ;;
    --data) need_value "$1" $#; data=$2; shift ;;
    --sources) need_value "$1" $#; sources=$2; shift ;;
    --accept-trip-count-change) need_value "$1" $#; accept=$2; shift ;;
    --dry-run) dry_run=1 ;;
    -h | --help) usage; exit 0 ;;
    *) usage_error "unknown argument '$1'" ;;
  esac
  shift
done
case $job in timetables | streets | streets-restored) ;; *) usage_error "--job needs timetables, streets or streets-restored" ;; esac
[[ -n $prev && -n $data && -n $sources ]] || usage_error "--prev, --data and --sources are required"
systems='(subway|bus|lirr|ferry|path)'
[[ -z $accept || $accept =~ ^$systems(,$systems)*$ ]] || usage_error "--accept-trip-count-change needs systems, comma-separated"
[[ -n ${BIKERIDE_DATA:-} && -x $BIKERIDE_DATA ]] || die "set BIKERIDE_DATA to the built bikeride-data"

read_state "$prev/state.env"
[[ $HOLD == 0 ]] || die "publishing is on hold: nothing to build"
if [[ $FIRST_RUN == 1 && $dry_run == 0 ]]; then
  die "a first run (no set in R2) is built only as a dry run: the first set is published from the Mac (scripts/publish-local.sh --first)"
fi
if [[ $job != timetables && ! -f $data/streets.bin ]]; then
  die "$data/streets.bin is missing: the streets step (or the fallback restore) comes first"
fi

args=(all --out "$data" --sources "$sources" --today "$BUILD_DAY")
case $job in
  timetables | streets-restored)
    args+=(--job timetables)
    if [[ $FIRST_RUN == 1 ]]; then
      [[ $job == timetables ]] || die "no previous set to fall back to"
      # Nothing to restore: streets and stations are built too.
      args+=(--skip flows)
    else
      args+=(--skip 'streets,stations,flows')
    fi
    ;;
  streets) args+=(--job streets --skip 'streets,flows') ;;
esac
if [[ $FIRST_RUN == 0 ]]; then
  args+=(--previous "$prev/manifest.json" --require-flows)
else
  log "first run (dry run): building without --previous and --require-flows; nothing will be published"
fi
[[ -z $accept ]] || args+=(--accept-trip-count-change "$accept")

log "bikeride-data ${args[*]}"
status=0
"$BIKERIDE_DATA" "${args[@]}" || status=$?
[[ $status -eq 0 ]] || die "bikeride-data all stopped with status $status" "$status"

if [[ -e $data/flows.bin || -e $data/flows.bin.xz ]]; then
  die "$data holds flows files; flows never reaches the public runner"
fi
report="$(dirname "$data")/reports/timetables.json"
if [[ -f $report ]] && grep -q 'built without entrances' "$report"; then
  die "the subway was built without entrances (no download and no cached copy): not published"
fi
log "built set $(jq -r '.setId // "?"' "$data/manifest.json" 2>/dev/null || echo '?')"

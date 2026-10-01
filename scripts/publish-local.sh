#!/usr/bin/env bash
# The Mac fallback: the same restore, bikeride-data all and publish steps as data-build.yml, with
# the data-bucket keys from an env file, in a fresh work directory. Used for the first set (M4 I2)
# and later only with the user's OK (docs/publish.md, "R2"). Every R2 call goes through
# scripts/r2.sh.
set -euo pipefail
SCRIPT='publish-local'
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

usage() {
  cat <<'USAGE'
USAGE: scripts/publish-local.sh --work DIR --env FILE [--flows-from DIR] [--flows-report FILE]
                                [--sources DIR] [--first] [--dry-run]

  1. Load the data-bucket keys from --env (read with sed, never sourced or printed).
  2. With --sources, seed <work>/sources from that cache (cloned on APFS).
  3. restore-state.sh --job streets into <work>/prev: the hold, the previous set and the source
     archive. With --first, data/manifest.json must be a 404 (and is then the re-read guard's
     expectation); without it, there must be a set.
  4. With --flows-from: copy flows.bin and flows.bin.xz into <work>/data and the flows report
     into <work>/reports/flows.json, so the set carries those flows. Required with --first.
  5. $BIKERIDE_DATA all --out <work>/data --sources <work>/sources --skip flows --require-flows
     --job all --today <build day> --strict-sources [--previous <work>/prev/manifest.json]
     [--cached-extracts, with --sources: a Geofabrik outage builds on the seeded extract]; then
     streets must have passed its sanity routes.
  6. sync-sources.sh upload (add-only; also after a failed build), then publish-set.sh, then,
     only when the set went out (not when a hold that began after the restore stopped it),
     sync-sources.sh prune and aux. No GC: that runs only in data-build.yml.

  --work DIR          A new directory (must not exist): data/, reports/, prev/, sources/
  --env FILE          KEY=value lines: R2_ACCOUNT_ID, R2_BUCKET (or R2_DATA_BUCKET) and the
                      data-bucket key pair as R2_DATA_ACCESS_KEY_ID / R2_DATA_SECRET_ACCESS_KEY,
                      R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY or AWS_ACCESS_KEY_ID /
                      AWS_SECRET_ACCESS_KEY; other lines are ignored
  --flows-from DIR    A data directory holding the flows.bin and flows.bin.xz to publish
  --flows-report FILE Its reports/flows.json (default <flows-from>/../reports/flows.json; for
                      build/data-m2c it is build/reports-m2c/flows.json)
  --sources DIR       Seed <work>/sources from this cache first (e.g. the OSM extract when
                      Geofabrik fails), and pass --cached-extracts so streets uses it when the
                      -latest and both dated extracts fail
  --first             The first set: no --previous, and the re-read guard expects a 404
  --dry-run           Build, then print the publish plan; write nothing to R2

$BIKERIDE_DATA defaults to .build/release/bikeride-data (swift build -c release --product
bikeride-data).

Exit status: 0 published (or held), 1 a failure, 64 usage; else the status of bikeride-data all.
USAGE
}

work='' env_file='' flows_from='' flows_report='' sources='' first=0 dry_run=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --work) need_value "$1" $#; work=$2; shift ;;
    --env) need_value "$1" $#; env_file=$2; shift ;;
    --flows-from) need_value "$1" $#; flows_from=$2; shift ;;
    --flows-report) need_value "$1" $#; flows_report=$2; shift ;;
    --sources) need_value "$1" $#; sources=$2; shift ;;
    --first) first=1 ;;
    --dry-run) dry_run=1 ;;
    -h | --help) usage; exit 0 ;;
    *) usage_error "unknown argument '$1'" ;;
  esac
  shift
done
[[ -n $work && -n $env_file ]] || usage_error "--work and --env are required"
[[ ! -e $work ]] || usage_error "--work $work exists; publish-local.sh builds in a fresh directory"
[[ -f $env_file ]] || usage_error "--env $env_file is not a file"
[[ -z $flows_report || -n $flows_from ]] || usage_error "--flows-report goes with --flows-from"
[[ $first == 0 || -n $flows_from ]] || usage_error "--first needs --flows-from: every set carries flows"
if [[ -n $flows_from ]]; then
  [[ -n $flows_report ]] || flows_report="$flows_from/../reports/flows.json"
  for file in "$flows_from/flows.bin" "$flows_from/flows.bin.xz" "$flows_report"; do
    [[ -f $file ]] || usage_error "$file is not a file"
  done
fi
[[ -z $sources || -d $sources ]] || usage_error "--sources $sources is not a directory"
repo=$(cd "$SCRIPTS_DIR/.." && pwd)
bikeride_data=${BIKERIDE_DATA:-$repo/.build/release/bikeride-data}
[[ -x $bikeride_data ]] || usage_error "$bikeride_data is not built (swift build -c release --product bikeride-data, or set BIKERIDE_DATA)"
need_tools jq xz

# 1. Keys: only the names below are taken, each value checked to be one plain word.
env_value() {
  local value
  value=$(sed -n "s/^$1=//p" "$env_file" | tail -n 1)
  value=${value%$'\r'}
  value=${value#\"}
  value=${value%\"}
  printf '%s' "$value"
}
first_value() {
  local name value
  for name in "$@"; do
    value=$(env_value "$name")
    if [[ -n $value ]]; then printf '%s' "$value"; return 0; fi
  done
}
R2_ACCOUNT_ID=$(env_value R2_ACCOUNT_ID)
R2_BUCKET=$(first_value R2_DATA_BUCKET R2_BUCKET)
AWS_ACCESS_KEY_ID=$(first_value R2_DATA_ACCESS_KEY_ID R2_ACCESS_KEY_ID AWS_ACCESS_KEY_ID)
AWS_SECRET_ACCESS_KEY=$(first_value R2_DATA_SECRET_ACCESS_KEY R2_SECRET_ACCESS_KEY AWS_SECRET_ACCESS_KEY)
for name in R2_ACCOUNT_ID R2_BUCKET AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
  [[ ${!name} =~ ^[A-Za-z0-9/+=_-]+$ ]] || usage_error "--env $env_file has no usable $name"
done
export R2_ACCOUNT_ID R2_BUCKET AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
unset R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ALLOW_PRIVATE_FLOWS R2_DRY_RUN

mkdir -p "$work/data" "$work/reports" "$work/prev" "$work/sources"
data="$work/data" prev="$work/prev"

# 2.
if [[ -n $sources ]]; then
  # Cloned on APFS (cp -c), so a seeded OSM extract takes no space.
  if [[ $(uname -s) == Darwin ]]; then cp -Rc "$sources/." "$work/sources/"; else cp -R "$sources/." "$work/sources/"; fi
  log "seeded $work/sources from $sources"
fi

# 3.
restore=(--job streets --prev "$prev" --sources "$work/sources" --data "$data")
[[ $first == 0 ]] || restore+=(--allow-first-run)
"$SCRIPTS_DIR/restore-state.sh" "${restore[@]}"
read_state "$prev/state.env"
if [[ $HOLD == 1 ]]; then
  log "publishing is on hold: nothing built or published"
  exit 0
fi
if [[ $first == 1 && $FIRST_RUN == 0 ]]; then
  die "--first, but R2 already has set $PREV_SET: run without --first"
fi

# 4.
if [[ -n $flows_from ]]; then
  cp "$flows_from/flows.bin" "$flows_from/flows.bin.xz" "$data/"
  cp "$flows_report" "$work/reports/flows.json"
  log "flows from $flows_from"
fi

# 5.
# --strict-sources: a subway without entrances stops all itself. --cached-extracts only with a
# seeded cache: on a fresh one there is no extract to fall back to.
args=(all --out "$data" --sources "$work/sources" --skip flows --require-flows --job all --today "$BUILD_DAY" --strict-sources)
[[ -z $sources ]] || args+=(--cached-extracts)
[[ $FIRST_RUN == 1 ]] || args+=(--previous "$prev/manifest.json")
status=0
"$bikeride_data" "${args[@]}" || status=$?
# all takes a failed streets sanity route (streets exit 2) as a warning; a published set may not.
if [[ $status -eq 0 ]] && ! jq -e '.sanity | type == "array" and all(.pass == true)' "$work/reports/streets.json" >/dev/null 2>&1; then
  log "streets did not pass its sanity routes (reports/streets.json): not published"
  status=1
fi

# 6.
sync=()
[[ $dry_run == 0 ]] || sync+=(--dry-run)
"$SCRIPTS_DIR/sync-sources.sh" upload --sources "$work/sources" ${sync[@]+"${sync[@]}"}
[[ $status -eq 0 ]] || die "bikeride-data all stopped with status $status; nothing published" "$status"
publish=(--data "$data" --prev "$prev" --result-file "$prev/publish.result")
[[ $dry_run == 0 ]] || publish+=(--dry-run)
"$SCRIPTS_DIR/publish-set.sh" "${publish[@]}"
published=$(sed -n 's/^published=//p' "$prev/publish.result" 2>/dev/null | tail -n 1)
if [[ $published == 0 ]]; then
  log "publishing went on hold during the run: nothing published, pruned or replaced"
  exit 0
fi
[[ $published == 1 ]] || die "publish-set.sh gave no result; stopping before the prune"
"$SCRIPTS_DIR/sync-sources.sh" prune --sources "$work/sources" --restored "$prev/sources-restored.txt" \
  --today "$BUILD_DAY" ${sync[@]+"${sync[@]}"}
"$SCRIPTS_DIR/sync-sources.sh" aux --sources "$work/sources" --files entrances,boundaries ${sync[@]+"${sync[@]}"}

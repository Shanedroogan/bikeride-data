#!/usr/bin/env bash
# The Mac fallback: the same restore, bikeride-data all and publish steps as data-build.yml, with
# the data-bucket keys from an env file, in a fresh work directory. Used for the first set (M4 I2)
# and later only with the user's OK (docs/publish.md, "R2").
# S0 stub: it parses its arguments and stops (exit 69); M4 lane Q writes the body, with tests
# against scripts/test/fake-aws. Every R2 call goes through scripts/r2.sh.
set -euo pipefail
SCRIPT=publish-local
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

usage() {
  cat <<'USAGE'
USAGE: scripts/publish-local.sh --work DIR --env FILE [--flows-from DIR] [--sources DIR] [--first]
                                [--dry-run]

  1. Load the data-bucket keys from --env (never printed).
  2. restore-state.sh into <work>/prev (skipped with --first, which instead requires data/manifest.json
     to be a 404).
  3. With --flows-from: copy flows.bin, flows.bin.xz and ../reports/flows.json into <work>/data and
     <work>/reports, so the set carries those flows.
  4. bikeride-data all --out <work>/data --sources <work>/sources --skip flows --require-flows
     [--previous <work>/prev/manifest.json].
  5. publish-set.sh.

  --work DIR        A new directory (must not exist): data/, reports/, prev/, sources/
  --env FILE        The env file with R2_ACCOUNT_ID, R2_BUCKET and the data-bucket key pair
  --flows-from DIR  A data directory holding the flows.bin to publish (its report in ../reports)
  --sources DIR     Seed <work>/sources from this cache first (e.g. the OSM extract when Geofabrik fails)
  --first           The first set: no --previous, and the re-read guard expects a 404
  --dry-run         Build, then print the publish plan; write nothing to R2

Exit status: 0 published, 1 a failure, 64 usage, 69 not implemented yet; else the status of
bikeride-data all.
USAGE
}

work='' env_file='' flows_from='' sources='' first=0 dry_run=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --work) need_value "$1" $#; work=$2; shift ;;
    --env) need_value "$1" $#; env_file=$2; shift ;;
    --flows-from) need_value "$1" $#; flows_from=$2; shift ;;
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
: "$flows_from" "$sources" "$first" "$dry_run"

# TODO(M4 lane Q): steps 1-5 above.
not_implemented

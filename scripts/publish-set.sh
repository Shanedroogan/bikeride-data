#!/usr/bin/env bash
# The only code that writes data/manifest.json. Called by data-build.yml, by the private flows.yml
# and by publish-local.sh (docs/publish.md, "R2").
# S0 stub: it parses its arguments and stops (exit 69); M4 lane Q writes the body, with tests
# against scripts/test/fake-aws. Every R2 call goes through scripts/r2.sh.
set -euo pipefail
SCRIPT=publish-set
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

usage() {
  cat <<'USAGE'
USAGE: scripts/publish-set.sh --data DIR --prev DIR [--dry-run]

Publishes the set bikeride-data all wrote to --data, in this order:
  1. HEAD every blob the new manifest references, carried ones included, and check ContentLength
     equals the manifest's bytes; PUT every locally built blob (always: they are content-addressed,
     and the PUT refreshes LastModified under the GC grace).
  2. PUT the trip-count sidecar as data/trip-counts/<sha256>.json.
  3. PUT the dated copy data/manifests/<YYYYMMDDTHHMMSSZ>-<setId>.json.
  4. Re-GET data/manifest.json and stop unless its setId is still PREV_SET from <prev>/state.env
     (or, on a first run, it is still a 404): another caller published in between.
  5. PUT data/manifest.json.
  6. PUT data/heartbeat.json, last.
A hold (data/hold.json) is checked again first: while one is active nothing is written (exit 0).
With --dry-run, every step is printed and nothing is written.

  --data DIR  The data directory: manifest.json, trip-counts.json, heartbeat.json and the *.bin.xz
  --prev DIR  What restore-state.sh wrote (state.env, manifest.json); state.env is read with
              sed and PREV_SET checked against ^[0-9a-f]{16}$ or empty, never sourced
  --dry-run   Print the plan; write nothing

Exit status: 0 published (or held), 1 a failure (nothing after the failed step was written),
64 usage, 69 not implemented yet.
USAGE
}

data='' prev='' dry_run=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --data) need_value "$1" $#; data=$2; shift ;;
    --prev) need_value "$1" $#; prev=$2; shift ;;
    --dry-run) dry_run=1 ;;
    -h | --help) usage; exit 0 ;;
    *) usage_error "unknown argument '$1'" ;;
  esac
  shift
done
[[ -n $data && -n $prev ]] || usage_error "--data and --prev are required"
: "$dry_run"

# TODO(M4 lane Q): steps 1-6 above.
not_implemented

#!/usr/bin/env bash
# Garbage collection of data/ (docs/publish.md, "R2"): data-build.yml, after a successful publish
# and inside its data-publish concurrency group, or alone with job=gc.
# S0 stub: it parses its arguments and stops (exit 69); M4 lane Q writes the body, with tests
# against scripts/test/fake-aws. Every R2 call goes through scripts/r2.sh.
set -euo pipefail
SCRIPT=gc-data
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

usage() {
  cat <<'USAGE'
USAGE: scripts/gc-data.sh [--dry-run] [--now ISO8601] [--max-deletions N]

  1. Re-read data/manifest.json and list data/manifests/ now (not from the start of the run).
  2. Roots: the current manifest and every retained dated manifest (the newest 7, plus all of
     the last 30 days).
  3. Delete blobs (data/blobs/) and sidecars (data/trip-counts/) no root references whose
     LastModified is more than 48 h old, and the dated manifests outside the retention.
  4. Fail if data/ is over 1.5 GB.
Fails closed: any list, GET or JSON error stops it before it deletes anything. Only data/ is
touched; at most --max-deletions objects go per run.

  --dry-run          Print the plan; delete nothing
  --now ISO8601      The time the 48 h grace and the 30 days count from (default now; tests pin it)
  --max-deletions N  Stop after N deletions (default 200)

Exit status: 0 done, 1 a failure, 64 usage, 69 not implemented yet.
USAGE
}

dry_run=0 now='' max_deletions=200
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) dry_run=1 ;;
    --now) need_value "$1" $#; check_time "$1" "$2"; now=$2; shift ;;
    --max-deletions) need_value "$1" $#; check_count "$1" "$2"; max_deletions=$2; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage_error "unknown argument '$1'" ;;
  esac
  shift
done
: "$dry_run" "$now" "$max_deletions"

# TODO(M4 lane Q): steps 1-4 above.
not_implemented

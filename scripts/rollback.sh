#!/usr/bin/env bash
# Puts an earlier published set back and holds publishing (docs/publish.md, "R2"). The setId does
# not change; generatedAt is re-stamped, so the app's "strictly newer" rule takes it.
# S0 stub: it parses its arguments and stops (exit 69); M4 lane Q writes the body, with tests
# against scripts/test/fake-aws. Every R2 call goes through scripts/r2.sh.
set -euo pipefail
SCRIPT=rollback
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

usage() {
  cat <<'USAGE'
USAGE: scripts/rollback.sh <setId> --reason TEXT [--until ISO8601] [--dry-run]

  1. Take the newest data/manifests/*-<setId>.json.
  2. HEAD every blob it references (ContentLength == bytes) and its trip-count sidecar.
  3. Re-stamp generatedAt to now.
  4. PUT it as data/manifest.json through the re-read guard (as publish-set.sh), with the dated copy.
  5. Write data/hold.json {reason, until}: every caller then exits 0 without publishing until the
     hold is removed by hand or its until passes.

  <setId>         The 16-hex setId to put back
  --reason TEXT   Why, recorded in the hold and the summary
  --until TIME    When the hold ends by itself (ISO 8601 UTC; default: only when removed by hand)
  --dry-run       Print the plan; write nothing

Exit status: 0 rolled back, 1 a failure (the guard tripped, a blob missing), 64 usage, 69 not
implemented yet.
USAGE
}

set_id='' reason='' until='' dry_run=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --reason) need_value "$1" $#; reason=$2; shift ;;
    --until) need_value "$1" $#; check_time "$1" "$2"; until=$2; shift ;;
    --dry-run) dry_run=1 ;;
    -h | --help) usage; exit 0 ;;
    -*) usage_error "unknown argument '$1'" ;;
    *)
      [[ -z $set_id ]] || usage_error "one setId only"
      set_id=$1
      ;;
  esac
  shift
done
[[ $set_id =~ ^[0-9a-f]{16}$ ]] || usage_error "a setId is 16 lowercase hex digits"
[[ -n $reason ]] || usage_error "--reason is required"
: "$until" "$dry_run"

# TODO(M4 lane Q): steps 1-5 above.
not_implemented

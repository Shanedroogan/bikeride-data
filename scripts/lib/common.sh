# shellcheck shell=bash
# Shared by the publishing scripts (sourced, not run). Each script sets SCRIPT before sourcing.
#
# Exit statuses the scripts share: 0 done (or nothing to do, such as an active hold); 1 a
# failure; 64 usage; 69 not implemented yet (an S0 stub: it parses its arguments, then stops
# before doing anything, so a workflow that calls it fails without touching R2).
set +x

readonly EX_USAGE=64 EX_UNAVAILABLE=69

log() { echo "$SCRIPT: $*" >&2; }
die() { echo "$SCRIPT: $1" >&2; exit "${2:-1}"; }
usage_error() { echo "$SCRIPT: $1 (see --help)" >&2; exit "$EX_USAGE"; }

# need_value OPTION ARGC: an option that takes a value has one.
need_value() { [[ $2 -ge 2 ]] || usage_error "$1 needs a value"; }

check_day() { [[ $2 =~ ^[0-9]{8}$ ]] || usage_error "$1 needs YYYYMMDD"; }
check_time() { [[ $2 =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || usage_error "$1 needs an ISO 8601 UTC time, e.g. 2026-10-07T12:00:00Z"; }
check_count() { [[ $2 =~ ^[1-9][0-9]*$ ]] || usage_error "$1 needs a positive integer"; }

# not_implemented: the end of an S0 stub, after its arguments parsed.
not_implemented() {
  die "not implemented yet (M4 lane Q); nothing was done" "$EX_UNAVAILABLE"
}

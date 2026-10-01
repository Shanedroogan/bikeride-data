#!/usr/bin/env bash
# Garbage collection of data/ (docs/publish.md, "R2"): data-build.yml, after a successful publish
# and inside its data-publish concurrency group, or alone with job=gc. Every R2 call goes
# through scripts/r2.sh.
set -euo pipefail
SCRIPT=gc-data
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

usage() {
  cat <<'USAGE'
USAGE: scripts/gc-data.sh [--dry-run] [--now ISO8601] [--max-deletions N] [--max-bytes N]

  1. Re-read data/manifest.json and list data/ now (not from the start of the run).
  2. Roots: the current manifest and every retained dated manifest (the newest 7, all of the
     last 30 days, and any copy of the current set), each read and checked.
  3. Delete blobs (data/blobs/) and sidecars (data/trip-counts/) no root names whose
     LastModified is more than 48 h old, and the dated manifests outside the retention.
  4. Fail if what is left under data/ is over --max-bytes.
Fails closed: any list, GET or parse error, or a key under data/manifests/ it cannot read,
stops it before it deletes anything. A plan of more than --max-deletions objects deletes none
and fails (check it with --dry-run; a person can rerun with a higher cap). With no
data/manifest.json there are no roots: it deletes nothing, and fails unless data/ holds no
blobs, sidecars or dated manifests either (an empty bucket before the first set). Only data/
is touched; data/manifest.json, data/heartbeat.json and data/hold.json never are.

  --dry-run          Print the plan; delete nothing
  --now ISO8601      The time the 48 h grace and the 30 days count from (default now; tests pin it)
  --max-deletions N  The largest plan it carries out (default 200)
  --max-bytes N      The size data/ may reach (default 1500000000, 1.5 GB)

Exit status: 0 done, 1 a failure, 64 usage.
USAGE
}

dry_run=0 now='' max_deletions=200 max_bytes=1500000000
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) dry_run=1 ;;
    --now) need_value "$1" $#; check_time "$1" "$2"; now=$2; shift ;;
    --max-deletions) need_value "$1" $#; check_count "$1" "$2"; max_deletions=$2; shift ;;
    --max-bytes) need_value "$1" $#; check_count "$1" "$2"; max_bytes=$2; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage_error "unknown argument '$1'" ;;
  esac
  shift
done
need_tools jq
if [[ $dry_run == 1 ]]; then export R2_DRY_RUN=1; else unset R2_DRY_RUN; fi
[[ -n $now ]] || now=$(now_iso)
now_epoch=$(epoch_of "$now") || die "unreadable --now"
grace_start=$((now_epoch - 48 * 3600))
retain_from=$((now_epoch - 30 * 86400))
work=$(mktemp -d "${TMPDIR:-/tmp}/gc-data.XXXXXX")
trap 'rm -rf "$work"' EXIT

# 1. The current set, then the listing.
rc=0
r2_get data/manifest.json "$work/current.json" || rc=$?
r2_list data/ "$work/listing"
if [[ $rc -eq $R2_NOT_FOUND ]]; then
  stray=$(grep -cE '^data/(blobs|trip-counts|manifests)/' "$work/listing" || true)
  [[ $stray -eq 0 ]] || die "no data/manifest.json, yet data/ holds $stray blobs, sidecars or dated manifests: no roots, so nothing is deleted; stopping"
  summary "no set published yet: nothing to collect"
  exit 0
fi
check_manifest "$work/current.json" "data/manifest.json"
current_set=$(json_value .setId "$work/current.json")

# 2. The dated manifests: every key must read as <YYYYMMDDTHHMMSSZ>-<setId>.json.
: >"$work/dated"
while IFS=$'\t' read -r key bytes modified; do
  [[ $key == data/manifests/* ]] || continue
  [[ $key =~ ^data/manifests/([0-9]{8})T([0-9]{6})Z-([0-9a-f]{16})\.json$ ]] ||
    die "unreadable key $key under data/manifests/: nothing is deleted; stopping"
  day=${BASH_REMATCH[1]} time=${BASH_REMATCH[2]} set=${BASH_REMATCH[3]}
  stamp_epoch=$(epoch_of "${day:0:4}-${day:4:2}-${day:6:2}T${time:0:2}:${time:2:2}:${time:4:2}Z") ||
    die "unreadable time in $key; stopping"
  printf '%s\t%s\t%s\t%s\n' "$stamp_epoch" "$key" "$set" "$bytes" >>"$work/dated"
done <"$work/listing"
sort -t $'\t' -k1,1nr -k2,2r "$work/dated" >"$work/dated.sorted"

: >"$work/roots"
: >"$work/plan"
add_roots() { # MANIFEST: its blob and sidecar keys
  jq -r '(.artifacts[] | "data/blobs/\(.sha).xz"), "data/trip-counts/\(.tripCounts.sha256).json"' "$1" >>"$work/roots"
}
add_roots "$work/current.json"
rank=0 retained=0
while IFS=$'\t' read -r stamp_epoch key set bytes; do
  rank=$((rank + 1))
  if [[ $rank -le 7 || $stamp_epoch -ge $retain_from || $set == "$current_set" ]]; then
    rc=0
    r2_get "$key" "$work/dated.json" || rc=$?
    [[ $rc -eq 0 ]] || die "$key vanished while collecting: nothing is deleted; stopping"
    check_manifest "$work/dated.json" "$key"
    [[ $(json_value .setId "$work/dated.json") == "$set" ]] || die "$key holds another set: nothing is deleted; stopping"
    add_roots "$work/dated.json"
    retained=$((retained + 1))
  else
    printf '%s\t%s\t%s\n' "$key" "$bytes" "dated manifest outside the retention" >>"$work/plan"
  fi
done <"$work/dated.sorted"
LC_ALL=C sort -u "$work/roots" -o "$work/roots"

# 3. Unreferenced blobs and sidecars past the grace.
young=0 kept=0
while IFS=$'\t' read -r key bytes modified; do
  case $key in
    data/blobs/*) [[ $key =~ ^data/blobs/[0-9a-f]{64}\.xz$ ]] || { log "warning: left $key (not a blob's key)"; continue; } ;;
    data/trip-counts/*) [[ $key =~ ^data/trip-counts/[0-9a-f]{64}\.json$ ]] || { log "warning: left $key (not a sidecar's key)"; continue; } ;;
    *) continue ;;
  esac
  if grep -Fxq "$key" "$work/roots"; then
    kept=$((kept + 1))
    continue
  fi
  modified_epoch=$(epoch_of "$modified") || die "unreadable LastModified for $key: nothing is deleted; stopping"
  if [[ $modified_epoch -ge $grace_start ]]; then
    young=$((young + 1))
    continue
  fi
  printf '%s\t%s\t%s\n' "$key" "$bytes" "unreferenced since before $(iso_of_epoch "$grace_start")" >>"$work/plan"
done <"$work/listing"

count=$(wc -l <"$work/plan" | tr -d ' ')
log "set $current_set; $retained dated manifests retained; $kept blobs and sidecars referenced," \
  "$young unreferenced but inside the 48 h grace; $count to delete"
if [[ $count -gt $max_deletions ]]; then
  die "the plan deletes $count objects, more than --max-deletions $max_deletions: nothing was deleted; check it with --dry-run"
fi
while IFS=$'\t' read -r key bytes why; do
  log "deleting $key ($why)"
  r2_delete "$key"
done <"$work/plan"

# 4. What is left.
total=$(awk -F '\t' -v plan="$work/plan" '
  BEGIN { while ((getline line < plan) > 0) { split(line, f, "\t"); gone[f[1]] = 1 } }
  !($1 in gone) { sum += $2 }
  END { printf "%.0f\n", sum }' "$work/listing")
if [[ $dry_run == 1 ]]; then
  summary "[dry run] would delete $count objects; data/ would hold $total bytes"
else
  summary "deleted $count objects; data/ holds $total bytes"
fi
[[ $total -le $max_bytes ]] || die "data/ holds $total bytes, over the $max_bytes limit"

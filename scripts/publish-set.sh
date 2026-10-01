#!/usr/bin/env bash
# The only code that writes data/manifest.json. Called by data-build.yml, by the private flows.yml
# and by publish-local.sh (docs/publish.md, "R2"). Every R2 call goes through scripts/r2.sh.
set -euo pipefail
SCRIPT=publish-set
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

usage() {
  cat <<'USAGE'
USAGE: scripts/publish-set.sh --data DIR --prev DIR [--no-flows-upload] [--result-file FILE] [--dry-run]
                              [--now ISO8601]

Publishes the set bikeride-data all wrote to --data. Before anything is written: the hold is
checked again (while one is active nothing is written, exit 0); the manifest is checked, and
must have been built on the set restore-state.sh restored (its previousSetId is PREV_SET, or it
has none on a first run); the sidecar and the heartbeat must be this set's. Then, in order:
  1. HEAD every carried blob (data/blobs/<sha>.xz) and check ContentLength equals the manifest's
     bytes; check every locally built blob's size and sha256 against the manifest, then PUT it
     (always: blobs are content-addressed, and the PUT refreshes LastModified under GC's grace).
     r2.sh HEADs each PUT and compares ContentLength.
  2. PUT the trip-count sidecar as data/trip-counts/<sha256>.json.
  3. PUT the dated copy data/manifests/<YYYYMMDDTHHMMSSZ>-<setId>.json (generatedAt).
  4. Re-GET data/manifest.json and stop unless its setId is still PREV_SET (or, on a first run,
     it is still a 404): another caller published in between, and the next run builds on that.
  5. PUT data/manifest.json.
  6. PUT data/heartbeat.json, last.
A failure stops at that step. A failure at step 4 or 5, or a race the guard stops, leaves the
blobs, the sidecar and the dated copy: nothing serves them, but the dated copy is a retained
manifest, so GC keeps it and what it names as long as it keeps any dated copy (30 days, longer
while it is among the newest 7), and rollback.sh could pick it by its setId. A failure before
step 3 leaves only blobs and perhaps the sidecar, which GC removes after 48 h.
With --dry-run every read still runs (the HEADs, the hold, the re-read guard) and every write is
printed instead.

  --data DIR          The data directory: manifest.json, trip-counts.json, heartbeat.json, *.bin.xz
  --prev DIR          What restore-state.sh wrote (state.env); state.env is read with sed and
                      checked, never sourced
  --no-flows-upload   Refuse a set whose flows blob is in --data: on the public runner flows is
                      only ever carried from the previous set
  --result-file FILE  Append published=1 (the set went out; on a dry run, would have) or
                      published=0 (a hold stopped it) to FILE. What follows a publish (pruning
                      sources, the auxiliary files, GC) runs only after published=1;
                      data-build.yml passes $GITHUB_OUTPUT
  --dry-run           Print the plan; write nothing
  --now TIME          The time the hold's until is compared with (default now; tests pin it)

Exit status: 0 published (or held: see --result-file), 1 a failure (nothing after the failed
step was written), 64 usage.
USAGE
}

data='' prev='' dry_run=0 no_flows=0 now='' result_file=''
while [[ $# -gt 0 ]]; do
  case $1 in
    --data) need_value "$1" $#; data=$2; shift ;;
    --prev) need_value "$1" $#; prev=$2; shift ;;
    --no-flows-upload) no_flows=1 ;;
    --result-file) need_value "$1" $#; result_file=$2; shift ;;
    --dry-run) dry_run=1 ;;
    --now) need_value "$1" $#; check_time "$1" "$2"; now=$2; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage_error "unknown argument '$1'" ;;
  esac
  shift
done
[[ -n $data && -n $prev ]] || usage_error "--data and --prev are required"
need_tools jq
[[ -n $now ]] || now=$(now_iso)
if [[ $dry_run == 1 ]]; then export R2_DRY_RUN=1; else unset R2_DRY_RUN; fi
# result VALUE: the outcome, for the caller (--result-file).
result() { if [[ -n $result_file ]]; then printf 'published=%s\n' "$1" >>"$result_file"; fi; }

read_state "$prev/state.env"
if [[ $HOLD == 1 ]]; then
  summary "publishing is on hold (see the restore step); nothing was published"
  result 0
  exit 0
fi

manifest="$data/manifest.json"
[[ -f $manifest ]] || die "$manifest is missing: nothing to publish"
check_manifest "$manifest" "$manifest"
set_id=$(json_value .setId "$manifest")
generated_at=$(json_value .generatedAt "$manifest")
previous=$(json_value '.previousSetId // ""' "$manifest")
if [[ $FIRST_RUN == 1 ]]; then
  [[ -z $previous ]] || die "a first run, but the manifest was built on set $previous; stopping"
else
  [[ $previous == "$PREV_SET" ]] ||
    die "the manifest was built on set ${previous:-(none)}, but R2's set was $PREV_SET at the restore; stopping"
fi

sidecar_sha=$(json_value .tripCounts.sha256 "$manifest")
[[ -f $data/trip-counts.json ]] || die "$data/trip-counts.json is missing"
got=$(sha256_of "$data/trip-counts.json") || die "cannot hash the sidecar"
[[ $got == "$sidecar_sha" ]] || die "$data/trip-counts.json is not the sidecar the manifest names; stopping"
[[ -f $data/heartbeat.json ]] || die "$data/heartbeat.json is missing"
jq -e --arg id "$set_id" '.setId == $id' "$data/heartbeat.json" >/dev/null 2>&1 ||
  die "$data/heartbeat.json does not name set $set_id; stopping"

carried=$(json_value '.carriedForward | join(" ")' "$manifest")
is_carried() { [[ " $carried " == *" $1 "* ]]; }
if [[ $no_flows == 1 ]] && json_value '.artifacts | has("flows")' "$manifest" | grep -qx true && ! is_carried flows; then
  die "the set's flows is built here, not carried: flows never leaves the private runner from this one; stopping"
fi

if hold_active "$now"; then
  summary "$HOLD_TEXT; set $set_id was not published"
  result 0
  exit 0
fi

names=$(json_value '.artifacts | keys | join(" ")' "$manifest")

# 1a. Every carried blob is already in R2, whole, before anything is written.
for name in $names; do
  is_carried "$name" || continue
  sha=$(json_value ".artifacts[\"$name\"].sha" "$manifest")
  bytes=$(json_value ".artifacts[\"$name\"].bytes" "$manifest")
  rc=0
  stored=$(r2_head_bytes "data/blobs/$sha.xz") || rc=$?
  [[ $rc -ne $R2_NOT_FOUND ]] || die "carried $name (data/blobs/$sha.xz) is not in R2; stopping"
  [[ $rc -eq 0 ]] || die "cannot HEAD carried $name; stopping"
  [[ $stored == "$bytes" ]] || die "carried $name: R2 holds $stored bytes, the manifest says $bytes; stopping"
  log "carried $name: in R2 ($bytes bytes)"
done

# 1b. Every built blob is the file the manifest describes.
for name in $names; do
  is_carried "$name" && continue
  sha=$(json_value ".artifacts[\"$name\"].sha" "$manifest")
  bytes=$(json_value ".artifacts[\"$name\"].bytes" "$manifest")
  file="$data/$name.bin.xz"
  [[ -f $file ]] || die "$file is missing, and $name is not carried; stopping"
  [[ $(size_of "$file") == "$bytes" ]] || die "$file's size is not the manifest's; stopping"
  got=$(sha256_of "$file") || die "cannot hash $file"
  [[ $got == "$sha" ]] || die "$file's sha256 is not the manifest's; stopping"
done

# 1c. PUT them, always.
for name in $names; do
  is_carried "$name" && continue
  r2_put "$data/$name.bin.xz" "data/blobs/$(json_value ".artifacts[\"$name\"].sha" "$manifest").xz"
done

# 2, 3.
r2_put "$data/trip-counts.json" "data/trip-counts/$sidecar_sha.json"
r2_put "$manifest" "$(dated_manifest_key "$generated_at" "$set_id")"

# 4. The re-read guard. TODO(M4 I2): if the probe shows R2 honours If-Match / If-None-Match on
# PutObject, send it with step 5 too, which makes this check atomic.
current=$(mktemp "${TMPDIR:-/tmp}/current.XXXXXX")
rc=0
r2_get data/manifest.json "$current" || rc=$?
if [[ $FIRST_RUN == 1 ]]; then
  if [[ $rc -eq 0 ]]; then
    rm -f "$current"
    die "a first run, but data/manifest.json appeared since the restore: another caller published; stopping"
  fi
else
  if [[ $rc -ne 0 ]]; then
    rm -f "$current"
    die "data/manifest.json disappeared since the restore; stopping"
  fi
  now_set=$(jq -r '.setId // ""' "$current" 2>/dev/null || true)
  if [[ $now_set != "$PREV_SET" ]]; then
    rm -f "$current"
    [[ $now_set =~ ^[0-9a-f]{16}$ ]] || now_set='(unreadable)'
    die "data/manifest.json is set $now_set now, not $PREV_SET as at the restore: another caller published; stopping"
  fi
fi
rm -f "$current"

# 5, 6.
r2_put "$manifest" data/manifest.json
r2_put "$data/heartbeat.json" data/heartbeat.json

if [[ $dry_run == 1 ]]; then
  summary "[dry run] set $set_id would be published (previous ${PREV_SET:-none}); nothing was written"
else
  summary "published set $set_id (previous ${PREV_SET:-none})"
fi
result 1

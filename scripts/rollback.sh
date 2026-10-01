#!/usr/bin/env bash
# Puts an earlier published set back and holds publishing (docs/publish.md, "R2"). The setId does
# not change; generatedAt is re-stamped, so the app's "strictly newer" rule takes it. Every R2
# call goes through scripts/r2.sh.
set -euo pipefail
SCRIPT=rollback
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

usage() {
  cat <<'USAGE'
USAGE: scripts/rollback.sh <setId> --reason TEXT [--until ISO8601] [--dry-run] [--now ISO8601]

  1. Take the newest data/manifests/*-<setId>.json.
  2. HEAD every blob it references (ContentLength == bytes) and its trip-count sidecar.
  3. Read the current data/manifest.json; re-stamp the old manifest's generatedAt to now, which
     must be later than the current one's.
  4. Write data/hold.json {reason, until} first: every caller then exits 0 without publishing
     until the hold is removed by hand or its until passes, so no run that restored before this
     one can publish over the rollback.
  5. PUT the re-stamped manifest as a new dated copy, then as data/manifest.json through the
     re-read guard (as publish-set.sh): it stops if the current set changed since step 3.
If step 5 stops, the hold stays: run rollback.sh again.

  <setId>         The 16-hex setId to put back
  --reason TEXT   Why, recorded in the hold (printable ASCII, at most 200 characters; it is
                  shown in the public step summary of every held run)
  --until TIME    When the hold ends by itself (ISO 8601 UTC; default: only when removed by hand)
  --dry-run       Print the plan; write nothing
  --now TIME      The re-stamp time (default now; tests pin it)

Exit status: 0 rolled back, 1 a failure (the guard tripped, a blob missing), 64 usage.
USAGE
}

set_id='' reason='' until='' dry_run=0 now=''
while [[ $# -gt 0 ]]; do
  case $1 in
    --reason) need_value "$1" $#; reason=$2; shift ;;
    --until) need_value "$1" $#; check_time "$1" "$2"; until=$2; shift ;;
    --now) need_value "$1" $#; check_time "$1" "$2"; now=$2; shift ;;
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
[[ ${#reason} -le 200 && $(printf '%s' "$reason" | LC_ALL=C tr -d '[:print:]') == '' ]] ||
  usage_error "--reason must be printable ASCII, at most 200 characters"
need_tools jq
[[ -n $now ]] || now=$(now_iso)
if [[ -n $until ]]; then
  until_epoch=$(epoch_of "$until") || usage_error "unreadable --until"
  now_epoch=$(epoch_of "$now") || usage_error "unreadable --now"
  [[ $until_epoch -gt $now_epoch ]] || usage_error "--until $until is not later than now ($now)"
fi
if [[ $dry_run == 1 ]]; then export R2_DRY_RUN=1; else unset R2_DRY_RUN; fi
work=$(mktemp -d "${TMPDIR:-/tmp}/rollback.XXXXXX")
trap 'rm -rf "$work"' EXIT

# 1.
r2_list data/manifests/ "$work/listing"
key=$(cut -f1 "$work/listing" | grep -E "^data/manifests/[0-9]{8}T[0-9]{6}Z-$set_id\.json\$" | LC_ALL=C sort | tail -n 1 || true)
[[ -n $key ]] || die "no dated manifest of set $set_id in data/manifests/ (GC keeps the newest 7 and 30 days)"
rc=0
r2_get "$key" "$work/old.json" || rc=$?
[[ $rc -eq 0 ]] || die "$key vanished; stopping"
check_manifest "$work/old.json" "$key"
[[ $(json_value .setId "$work/old.json") == "$set_id" ]] || die "$key holds another set; stopping"
log "rolling back to set $set_id, from $key"

# 2.
for name in $(json_value '.artifacts | keys | join(" ")' "$work/old.json"); do
  sha=$(json_value ".artifacts[\"$name\"].sha" "$work/old.json")
  bytes=$(json_value ".artifacts[\"$name\"].bytes" "$work/old.json")
  rc=0
  stored=$(r2_head_bytes "data/blobs/$sha.xz") || rc=$?
  [[ $rc -ne $R2_NOT_FOUND ]] || die "set $set_id's $name (data/blobs/$sha.xz) is no longer in R2: it cannot be put back"
  [[ $rc -eq 0 ]] || die "cannot HEAD $name's blob; stopping"
  [[ $stored == "$bytes" ]] || die "set $set_id's $name: R2 holds $stored bytes, the manifest says $bytes; stopping"
done
sidecar=$(json_value .tripCounts.sha256 "$work/old.json")
rc=0
r2_head_bytes "data/trip-counts/$sidecar.json" >/dev/null || rc=$?
[[ $rc -ne $R2_NOT_FOUND ]] || die "set $set_id's trip-count sidecar is no longer in R2: the next build's gate would fail"
[[ $rc -eq 0 ]] || die "cannot HEAD the sidecar; stopping"

# 3.
rc=0
r2_get data/manifest.json "$work/current.json" || rc=$?
[[ $rc -eq 0 ]] || die "no data/manifest.json: nothing to roll back from"
check_manifest "$work/current.json" "data/manifest.json"
current_set=$(json_value .setId "$work/current.json")
current_at=$(json_value .generatedAt "$work/current.json")
now_epoch=$(epoch_of "$now") || die "unreadable --now"
current_epoch=$(epoch_of "$current_at") || die "unreadable generatedAt in data/manifest.json"
[[ $now_epoch -gt $current_epoch ]] ||
  die "now ($now) is not later than the current set's generatedAt ($current_at): the app would not take the rollback"
jq -cjS --arg at "$now" '.generatedAt = $at' "$work/old.json" >"$work/manifest.json"
jq -n -cjS --arg reason "$reason" --arg until "$until" \
  '{reason: $reason} + (if $until == "" then {} else {until: $until} end)' >"$work/hold.json"

# 4, 5.
r2_put "$work/hold.json" data/hold.json
r2_put "$work/manifest.json" "$(dated_manifest_key "$now" "$set_id")"
rc=0
r2_get data/manifest.json "$work/again.json" || rc=$?
[[ $rc -eq 0 && $(jq -r '.setId // ""' "$work/again.json" 2>/dev/null || true) == "$current_set" ]] ||
  die "data/manifest.json changed since it was read (another caller published): not rolled back; the hold stays; run rollback.sh again"
r2_put "$work/manifest.json" data/manifest.json

if [[ $dry_run == 1 ]]; then
  summary "[dry run] would roll back from set $current_set to $set_id, generatedAt $now, and hold publishing; nothing was written"
else
  summary "rolled back from set $current_set to $set_id (generatedAt $now); publishing is on hold: remove data/hold.json by hand${until:+ or wait until $until}"
fi

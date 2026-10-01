#!/usr/bin/env bash
# Restores what a publish run starts from: data-build.yml's restore step, the private flows.yml
# and publish-local.sh. Every R2 call goes through scripts/r2.sh.
set -euo pipefail
SCRIPT=restore-state
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

usage() {
  cat <<'USAGE'
USAGE: scripts/restore-state.sh --job timetables|streets|flows --prev DIR --sources DIR --data DIR
                                [--allow-first-run] [--today YYYYMMDD] [--now ISO8601]
       scripts/restore-state.sh --blobs-only --prev DIR --data DIR

In order (docs/publish.md, "R2"):
  1. data/hold.json: while a hold is active, write HOLD=1 and a summary line, and exit 0.
  2. data/manifest.json, data/heartbeat.json and the trip-count sidecar (data/trip-counts/<sha256>.json,
     by the manifest's tripCounts.sha256) into --prev as manifest.json, heartbeat.json and
     trip-counts.json. A 404 on the manifest is a first run: refused (exit 1) unless
     --allow-first-run (a dry run, or publish-local.sh --first), and then FIRST_RUN=1. A 403 or
     5xx fails.
  3. timetables and streets: sources/ records whose calendarEnd >= today - 1 into
     <sources>/gtfs/archive/<feed>/ (the builder's archive), each zip checked against its
     record's sha256 and size. sources/aux/subway-entrances.csv and
     sources/aux/borough-boundaries.geojson into <sources>/nyc/subway-entrances.csv and
     <sources>/nyc/borough-boundaries-water-included.geojson, unless already there: stamped
     1970-01-01 UTC with no .etag or .source.json, so the builder's conditional download still
     fetches a newer file and the copy is used only when that fails. What R2 held goes to
     <prev>/sources-restored.txt for sync-sources.sh prune.
  4. timetables: the streets and stations blobs into --data, by the manifest's sha, checked by
     size, sha256, xz -dc and rawSha256.
  5. timetables and streets: fail if --data holds a flows.bin (flows never reaches the public runner).
--job flows (the private flows.yml) does steps 1 and 2 only: no sources/ archive, no auxiliary
files and no blobs; flows.yml restores the flows blob itself.

--blobs-only does step 4 alone, from the <prev>/manifest.json an earlier restore wrote, replacing
any streets and stations files in --data: the streets job's fallback when the new streets build
failed or its sanity routes did not pass.

Writes <prev>/state.env, one KEY=value per line with printf, no quotes: PREV_SET (the
manifest's setId, checked against ^[0-9a-f]{16}$; empty on a first run), FIRST_RUN and HOLD
(0 or 1), BUILD_DAY (YYYYMMDD). PREV_SET comes from R2, so readers take values with sed and
check them; none sources the file.

<prev>/sources-restored.txt has one line per record R2 held: "<feed>/<key>", its calendarEnd
(YYYYMMDD, or - for none) and 1 if restored, 0 if too old for this build, tab-separated.

  --job NAME         timetables, streets (data-build.yml) or flows (flows.yml)
  --prev DIR         Where the previous set's documents go (the --previous of bikeride-data all);
                     must be new or empty
  --sources DIR      The builder's source cache (the --sources of bikeride-data all)
  --data DIR         The data directory the run builds into (the --out of bikeride-data all)
  --allow-first-run  A missing data/manifest.json is a first run, not a failure
  --today DATE       Build day (default today in New York)
  --now TIME         The time a hold's until is compared with (default now; tests pin it)
  --blobs-only       Only step 4, as above

Exit status: 0 restored (or a hold is active), 1 a failure, 64 usage.
USAGE
}

job='' prev='' sources='' data='' today='' now='' allow_first=0 blobs_only=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --job) need_value "$1" $#; job=$2; shift ;;
    --prev) need_value "$1" $#; prev=$2; shift ;;
    --sources) need_value "$1" $#; sources=$2; shift ;;
    --data) need_value "$1" $#; data=$2; shift ;;
    --today) need_value "$1" $#; check_day "$1" "$2"; today=$2; shift ;;
    --now) need_value "$1" $#; check_time "$1" "$2"; now=$2; shift ;;
    --allow-first-run) allow_first=1 ;;
    --blobs-only) blobs_only=1 ;;
    -h | --help) usage; exit 0 ;;
    *) usage_error "unknown argument '$1'" ;;
  esac
  shift
done
if [[ $blobs_only == 1 ]]; then
  [[ -z $job && -z $sources && -n $prev && -n $data ]] || usage_error "--blobs-only takes --prev and --data only"
else
  case $job in timetables | streets | flows) ;; *) usage_error "--job needs timetables, streets or flows" ;; esac
  [[ -n $prev && -n $sources && -n $data ]] || usage_error "--prev, --sources and --data are required"
fi
need_tools jq xz

# restore_blob NAME: <data>/<NAME>.bin.xz and <NAME>.bin from the blob <prev>/manifest.json names.
restore_blob() {
  local name=$1 manifest="$prev/manifest.json" set_id sha bytes raw got rc=0
  set_id=$(json_value .setId "$manifest")
  sha=$(json_value ".artifacts[\"$name\"].sha // \"\"" "$manifest")
  bytes=$(json_value ".artifacts[\"$name\"].bytes // \"\"" "$manifest")
  raw=$(json_value ".artifacts[\"$name\"].rawSha256 // \"\"" "$manifest")
  [[ -n $sha ]] || die "set $set_id has no $name to restore"
  rm -f "$data/$name.bin" "$data/$name.bin.xz" "$data/$name.bin.partial"
  r2_get "data/blobs/$sha.xz" "$data/$name.bin.xz" || rc=$?
  [[ $rc -eq 0 ]] || die "data/blobs/$sha.xz ($name of set $set_id) is missing; stopping"
  got=$(size_of "$data/$name.bin.xz")
  [[ $got == "$bytes" ]] || die "the $name blob has $got bytes, the manifest says $bytes; stopping"
  got=$(sha256_of "$data/$name.bin.xz") || die "cannot hash the $name blob"
  [[ $got == "$sha" ]] || die "the $name blob's sha256 is $got, the manifest says $sha; stopping"
  xz -dc "$data/$name.bin.xz" >"$data/$name.bin.partial" || die "the $name blob does not decompress; stopping"
  got=$(sha256_of "$data/$name.bin.partial") || die "cannot hash $name.bin"
  [[ $got == "$raw" ]] || die "$name.bin's sha256 is $got, the manifest's rawSha256 is $raw; stopping"
  mv -f "$data/$name.bin.partial" "$data/$name.bin"
  log "restored $name from set $set_id"
}

mkdir -p "$data"
if [[ $blobs_only == 1 ]]; then
  [[ -f $prev/manifest.json ]] || die "$prev/manifest.json is missing: the fallback needs a previous set"
  check_manifest "$prev/manifest.json" "$prev/manifest.json"
  restore_blob streets
  restore_blob stations
  exit 0
fi

mkdir -p "$prev"
[[ -z $(ls -A "$prev") ]] || die "--prev $prev is not empty; restore into a new directory"
[[ -n $today ]] || today=$(today_new_york)
[[ -n $now ]] || now=$(now_iso)

write_state() { # HOLD FIRST_RUN PREV_SET
  printf 'HOLD=%s\nFIRST_RUN=%s\nPREV_SET=%s\nBUILD_DAY=%s\n' "$1" "$2" "$3" "$today" >"$prev/state.env"
}

# 1. The hold.
if hold_active "$now"; then
  write_state 1 0 ''
  summary "$HOLD_TEXT; nothing is built or published"
  exit 0
fi

# 2. The previous set.
first_run=0 prev_set='' rc=0
r2_get data/manifest.json "$prev/manifest.json" || rc=$?
if [[ $rc -eq $R2_NOT_FOUND ]]; then
  [[ $allow_first == 1 ]] ||
    die "no data/manifest.json in R2: the first set is published from the Mac (scripts/publish-local.sh --first)"
  first_run=1
  log "no data/manifest.json in R2: a first run, nothing to restore"
else
  check_manifest "$prev/manifest.json" "data/manifest.json"
  prev_set=$(json_value .setId "$prev/manifest.json")
  rc=0
  r2_get data/heartbeat.json "$prev/heartbeat.json" || rc=$?
  [[ $rc -eq 0 ]] || log "no data/heartbeat.json in R2: lastTimetableSuccessAt starts over"
  sidecar=$(json_value .tripCounts.sha256 "$prev/manifest.json")
  rc=0
  r2_get "data/trip-counts/$sidecar.json" "$prev/trip-counts.json" || rc=$?
  [[ $rc -eq 0 ]] || die "data/trip-counts/$sidecar.json (set $prev_set's sidecar) is missing; stopping"
  got=$(sha256_of "$prev/trip-counts.json") || die "cannot hash the sidecar"
  [[ $got == "$sidecar" ]] || die "data/trip-counts/$sidecar.json's sha256 is $got; stopping"
  log "previous set $prev_set, generated $(json_value .generatedAt "$prev/manifest.json")"
fi

# 3. The source archive and the auxiliary files: the builder's cache.
restore_sources() {
  local listing keys record oldest key rel feed k end restored dest got rc
  listing=$(mktemp "${TMPDIR:-/tmp}/sources.XXXXXX")
  keys="$listing.keys" record="$listing.record"
  r2_list sources/ "$listing"
  cut -f1 "$listing" >"$keys"
  oldest=$(day_add "$today" -1) || die "cannot count back from $today"
  : >"$prev/sources-restored.txt"
  # shellcheck disable=SC2094 # the loop and the grep in it only read the listing
  while IFS= read -r key; do
    case $key in sources/aux/*) continue ;; sources/*/*.json) ;; *) continue ;; esac
    rel=${key#sources/}
    feed=${rel%%/*}
    k=${rel#*/}
    k=${k%.json}
    if ! [[ $feed =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ && $k =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]]; then
      log "skipped $key: not a source record's key"
      continue
    fi
    if ! grep -Fxq "sources/$feed/$k.zip" "$keys"; then
      log "skipped $key: no zip beside it (an upload that stopped half way; the next upload adds it)"
      continue
    fi
    rc=0
    r2_get "$key" "$record" || rc=$?
    [[ $rc -eq 0 ]] || die "$key vanished while restoring; stopping"
    jq -e --arg feed "$feed" --arg key "$k" '.feed == $feed and .key == $key
        and (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
        and (.bytes | type == "number" and . > 0)
        and ((.calendarEnd // "00000000") | type == "string" and test("^[0-9]{8}$"))' "$record" >/dev/null 2>&1 ||
      die "$key is not a source record for $feed/$k; stopping"
    end=$(jq -r '.calendarEnd // "-"' "$record")
    restored=0
    # A record with no calendar cannot be shown to be over, so it is kept.
    if [[ $end == - ]] || ! [[ $end < $oldest ]]; then
      dest="$sources/gtfs/archive/$feed"
      mkdir -p "$dest"
      if [[ -f $dest/$k.zip && -f $dest/$k.json ]]; then
        log "kept $feed/$k from the local cache"
      else
        rc=0
        r2_get "sources/$feed/$k.zip" "$dest/$k.zip" || rc=$?
        [[ $rc -eq 0 ]] || die "sources/$feed/$k.zip vanished while restoring; stopping"
        got=$(size_of "$dest/$k.zip")
        [[ $got == "$(jq -r .bytes "$record")" ]] || die "sources/$feed/$k.zip's size does not match its record; stopping"
        got=$(sha256_of "$dest/$k.zip") || die "cannot hash $feed/$k.zip"
        [[ $got == "$(jq -r .sha256 "$record")" ]] || die "sources/$feed/$k.zip does not match its record's sha256; stopping"
        cp "$record" "$dest/$k.json"
      fi
      restored=1
    fi
    printf '%s/%s\t%s\t%s\n' "$feed" "$k" "$end" "$restored" >>"$prev/sources-restored.txt"
  done <"$keys"
  rm -f "$listing" "$keys" "$record"
  log "restored $(awk -F '\t' '$3 == 1' "$prev/sources-restored.txt" | wc -l | tr -d ' ') source versions" \
    "of the $(wc -l <"$prev/sources-restored.txt" | tr -d ' ') in R2"

  # The last good copy of each auxiliary file, used only when its download fails. Its time stamp
  # goes back to 1970 (UTC): the fetcher sends If-Modified-Since from it, and a copy stamped "now"
  # would be answered 304 from then on and never refreshed. Any .etag or .source.json left beside
  # it described another copy: an old ETag would be answered 304 (If-None-Match wins over
  # If-Modified-Since) and keep this copy, so they go.
  local pair r2_key local_file
  for pair in "sources/aux/subway-entrances.csv nyc/subway-entrances.csv" \
    "sources/aux/borough-boundaries.geojson nyc/borough-boundaries-water-included.geojson"; do
    r2_key=${pair%% *}
    local_file="$sources/${pair#* }"
    if [[ -f $local_file ]]; then
      log "kept ${pair#* } from the local cache"
      continue
    fi
    mkdir -p "$(dirname "$local_file")"
    rm -f "$local_file.etag" "$local_file.source.json"
    rc=0
    r2_get "$r2_key" "$local_file" || rc=$?
    if [[ $rc -eq 0 ]]; then
      TZ=UTC touch -t 197001010000 "$local_file"
      log "restored ${pair#* } (the fallback if its download fails)"
    else
      log "no $r2_key in R2 yet"
    fi
  done
}

case $job in timetables | streets) restore_sources ;; esac

# 4. A timetables run carries streets and stations: restored, so links and the gate can read them.
if [[ $job == timetables && $first_run == 0 ]]; then
  restore_blob streets
  restore_blob stations
fi

# 5. Flows never reaches the public runner.
if [[ $job != flows ]] && [[ -e $data/flows.bin || -e $data/flows.bin.xz ]]; then
  die "$data holds flows files; flows never reaches the public runner"
fi

write_state 0 "$first_run" "$prev_set"
if [[ $first_run == 1 ]]; then
  summary "first run: no set in R2 yet, so nothing was restored"
fi

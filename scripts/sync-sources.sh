#!/usr/bin/env bash
# The GTFS source archive mirrored in R2 under sources/ (docs/publish.md, "R2"): new records
# uploaded add-only on every real run, even a failing one, and deletions and the auxiliary files
# only after a publish. Every R2 call goes through scripts/r2.sh.
set -euo pipefail
SCRIPT=sync-sources
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

usage() {
  cat <<'USAGE'
USAGE: scripts/sync-sources.sh upload --sources DIR [--dry-run]
       scripts/sync-sources.sh prune  --sources DIR --restored FILE --today YYYYMMDD
                                      [--max-deletions N] [--dry-run]
       scripts/sync-sources.sh aux    --sources DIR --files entrances[,boundaries] [--dry-run]

  upload  Add-only: PUT each archived version in <sources>/gtfs/archive/<feed>/ as
          sources/<feed>/<key>.zip, then .json, when that key is not in R2 yet; a key already
          there is never overwritten. Each zip is checked against its record's sha256 and size
          first. Never deletes. data-build.yml runs it with if: always() on real runs, so a
          version first seen by a run that then failed is kept. Also seeds sources/ from the
          Mac's cache (M4 I2).
  prune   After a successful publish only: delete the records this build pruned (restored, in
          --restored, and no longer in the archive) and those whose calendarEnd < today - 30,
          the .json first, then the .zip.
  aux     After a successful publish only: PUT the auxiliary files the build used when they
          differ from R2's copy (by MD5): entrances (nyc/subway-entrances.csv as
          sources/aux/subway-entrances.csv), boundaries (nyc/borough-boundaries-water-included.geojson
          as sources/aux/borough-boundaries.geojson; only when streets was rebuilt).

  --sources DIR       The builder's source cache
  --restored FILE     What restore-state.sh listed (<prev>/sources-restored.txt)
  --today DATE        Build day
  --max-deletions N   Prune refuses a plan of more than N objects, deleting none (default 200)
  --files LIST        aux: which files, comma-separated
  --dry-run           Print the plan; write and delete nothing

Exit status: 0 done, 1 a failure (upload: after uploading every good record), 64 usage.
USAGE
}

[[ $# -ge 1 ]] || usage_error "upload, prune or aux?"
case $1 in
  -h | --help) usage; exit 0 ;;
  upload | prune | aux) mode=$1; shift ;;
  *) usage_error "unknown command '$1'" ;;
esac
sources='' restored='' today='' dry_run=0 max_deletions=200 files=''
while [[ $# -gt 0 ]]; do
  case $1 in
    --sources) need_value "$1" $#; sources=$2; shift ;;
    --restored) need_value "$1" $#; restored=$2; shift ;;
    --today) need_value "$1" $#; check_day "$1" "$2"; today=$2; shift ;;
    --max-deletions) need_value "$1" $#; check_count "$1" "$2"; max_deletions=$2; shift ;;
    --files) need_value "$1" $#; files=$2; shift ;;
    --dry-run) dry_run=1 ;;
    -h | --help) usage; exit 0 ;;
    *) usage_error "unknown argument '$1'" ;;
  esac
  shift
done
[[ -n $sources ]] || usage_error "--sources is required"
case $mode in
  prune) [[ -n $restored && -n $today ]] || usage_error "prune needs --restored and --today" ;;
  aux) [[ $files =~ ^(entrances|boundaries)(,(entrances|boundaries))*$ ]] || usage_error "aux needs --files entrances[,boundaries]" ;;
esac
need_tools jq
if [[ $dry_run == 1 ]]; then export R2_DRY_RUN=1; else unset R2_DRY_RUN; fi
archive="$sources/gtfs/archive"
plain='^[A-Za-z0-9_][A-Za-z0-9._-]*$'
work=$(mktemp -d "${TMPDIR:-/tmp}/sync-sources.XXXXXX")
trap 'rm -rf "$work"' EXIT

upload() {
  local bad=0 added=0 record dir feed k zip ext key local_file stored got
  if [[ ! -d $archive ]]; then
    log "no $archive: nothing to upload"
    return 0
  fi
  r2_list sources/ "$work/listing"
  find "$archive" -mindepth 2 -maxdepth 2 -type f -name '*.json' | LC_ALL=C sort >"$work/records"
  while IFS= read -r record; do
    dir=$(dirname "$record")
    feed=$(basename "$dir")
    k=$(basename "$record" .json)
    if ! [[ $feed =~ $plain && $k =~ $plain ]] || [[ $feed == aux ]]; then
      log "skipped $record: not an archive record's path"
      bad=1
      continue
    fi
    zip="$dir/$k.zip"
    if [[ ! -f $zip ]] ||
      ! jq -e --arg feed "$feed" --arg key "$k" '.feed == $feed and .key == $key
          and (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and (.bytes | type == "number")' "$record" >/dev/null 2>&1; then
      log "skipped $feed/$k: no zip, or a record that does not name it"
      bad=1
      continue
    fi
    got=$(sha256_of "$zip") || die "cannot hash $zip"
    if [[ $got != "$(jq -r .sha256 "$record")" || $(size_of "$zip") != "$(jq -r .bytes "$record")" ]]; then
      log "skipped $feed/$k: the zip does not match its record"
      bad=1
      continue
    fi
    # The zip first: a record in R2 always has its zip beside it.
    for ext in zip json; do
      key="sources/$feed/$k.$ext"
      local_file="$dir/$k.$ext"
      stored=$(awk -F '\t' -v key="$key" '$1 == key { print $2 }' "$work/listing")
      if [[ -z $stored ]]; then
        r2_put "$local_file" "$key"
        added=$((added + 1))
      elif [[ $stored != "$(size_of "$local_file")" ]]; then
        log "warning: $key in R2 differs in size from the local file; add-only, so it is left as it is"
      fi
    done
  done <"$work/records"
  log "uploaded $added new source files"
  [[ $bad == 0 ]] || die "some local records were not uploaded (above)"
}

prune() {
  local oldest path end was_restored feed k count=0 why
  [[ -f $restored ]] || die "$restored is missing: run restore-state.sh first"
  if awk -F '\t' '$3 == 1' "$restored" | grep -q . && [[ ! -d $archive ]]; then
    die "$archive is missing, yet sources were restored into it: every record would look pruned; stopping"
  fi
  oldest=$(day_add "$today" -30) || die "cannot count back from $today"
  : >"$work/plan"
  while IFS=$'\t' read -r path end was_restored; do
    feed=${path%%/*}
    k=${path#*/}
    [[ $feed =~ $plain && $k =~ $plain && $path == "$feed/$k" ]] || die "$restored: unreadable line '$path'; stopping"
    [[ $end == - || $end =~ ^[0-9]{8}$ ]] || die "$restored: unreadable calendarEnd for $path; stopping"
    why=''
    if [[ $was_restored == 1 && ! -f $archive/$feed/$k.json ]]; then
      why="pruned by this build"
    elif [[ $end != - ]] && [[ $end < $oldest ]]; then
      why="calendar ended $end"
    fi
    [[ -n $why ]] || continue
    printf 'sources/%s/%s.json\t%s\n' "$feed" "$k" "$why" >>"$work/plan"
    printf 'sources/%s/%s.zip\t%s\n' "$feed" "$k" "$why" >>"$work/plan"
  done <"$restored"
  count=$(wc -l <"$work/plan" | tr -d ' ')
  if [[ $count -gt $max_deletions ]]; then
    die "the prune plan deletes $count objects, more than --max-deletions $max_deletions: nothing was deleted; check it with --dry-run"
  fi
  while IFS=$'\t' read -r path why; do
    log "deleting $path ($why)"
    r2_delete "$path"
  done <"$work/plan"
  log "pruned $((count / 2)) source versions"
}

aux() {
  local pair name key local_file rc line md5
  for pair in "entrances sources/aux/subway-entrances.csv nyc/subway-entrances.csv" \
    "boundaries sources/aux/borough-boundaries.geojson nyc/borough-boundaries-water-included.geojson"; do
    read -r name key local_file <<<"$pair"
    [[ ,$files, == *",$name,"* ]] || continue
    local_file="$sources/$local_file"
    if [[ ! -f $local_file ]]; then
      log "no $local_file: $key left as it is"
      continue
    fi
    rc=0
    line=$("$R2" head "$key") || rc=$?
    md5=$(md5_of "$local_file") || die "cannot hash $local_file"
    case $rc in
      0) if [[ $(printf '%s' "$line" | cut -f2) == "$md5" ]]; then log "$key is current"; continue; fi ;;
      "$R2_NOT_FOUND") ;;
      *) die "cannot HEAD $key (r2 exit $rc); stopping" ;;
    esac
    r2_put "$local_file" "$key"
  done
}

"$mode"

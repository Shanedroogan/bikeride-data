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
          the .json first, then the .zip. A version is kept, never deleted, when the live set
          (data/manifest.json) names it, current or archived (by ETag), or when R2 holds no
          other copy of its feed that is not older (Last-Modified, then archivedAt, as the
          compiler orders them) and confirmed whole: a copy from this build's archive by HEAD
          with its zip's and record's local size and MD5 (a newer version whose upload failed
          does not count), one only in R2 by its record and a HEAD of its zip with the record's
          bytes. Every read comes before the first delete; a failed LIST, GET or HEAD (not a
          404) deletes nothing and warns in the summary, exit 0.
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

# The sort stamp of a record, as GTFSSourceArchive.Record orders versions of one feed:
# [Last-Modified as ISO 8601 (else archivedAt), archivedAt]. jq compares arrays element by element.
# shellcheck disable=SC2016 # a jq program, not shell
STAMP='def stamp: [((.lastModified | try (strptime("%a, %d %b %Y %H:%M:%S GMT") | todate) catch null) // .archivedAt), .archivedAt];'

# keep_all WHY: a read the guard needs failed; nothing is deleted.
keep_all() {
  summary "warning: $1: nothing was pruned (the next publish tries again)"
}

# confirm_copy FEED KEY RECORD: whether R2 holds version KEY of FEED whole. 0 confirmed; 1 not; 2
# a HEAD failed (not a 404). A version in the local archive must match its record there, and R2
# must hold its zip and record with the local sizes and MD5s (the ETag of a single-part PUT). A
# version only in R2 (RECORD, read from there) must have its record listed and its zip HEAD to the
# record's bytes, as publish-set.sh confirms a carried blob. Results are cached in
# $work/confirmed.
confirm_copy() {
  local feed=$1 k=$2 record=$3 dir="$archive/$1" cached ext key local_file bytes sha md5 rc line result=0
  cached=$(awk -F '\t' -v id="$feed/$k" '$1 == id { print $2 }' "$work/confirmed")
  [[ -z $cached ]] || return "$cached"
  if ! jq -e --arg feed "$feed" --arg key "$k" '.feed == $feed and .key == $key
      and (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and (.bytes | type == "number")' "$record" >/dev/null 2>&1; then
    result=1
  elif [[ -f $dir/$k.json ]]; then
    if [[ -f $dir/$k.zip ]]; then
      sha=$(sha256_of "$dir/$k.zip") || die "cannot hash $dir/$k.zip"
      [[ $sha == "$(jq -r .sha256 "$record")" && $(size_of "$dir/$k.zip") == "$(jq -r .bytes "$record")" ]] || result=1
    else
      result=1
    fi
    for ext in zip json; do
      [[ $result == 0 ]] || break
      key="sources/$feed/$k.$ext"
      local_file="$dir/$k.$ext"
      bytes=$(size_of "$local_file")
      # The listing first: a key it does not show (an upload that failed) needs no HEAD.
      if [[ $(awk -F '\t' -v key="$key" '$1 == key { print $2 }' "$work/listing") != "$bytes" ]]; then
        result=1
        break
      fi
      md5=$(md5_of "$local_file") || die "cannot hash $local_file"
      rc=0
      line=$("$R2" head "$key") || rc=$?
      case $rc in
        0) [[ $(printf '%s' "$line" | cut -f1) == "$bytes" && $(printf '%s' "$line" | cut -f2) == "$md5" ]] || result=1 ;;
        "$R2_NOT_FOUND") result=1 ;;
        *) result=2 ;;
      esac
    done
  else
    rc=0
    line=$("$R2" head "sources/$feed/$k.zip") || rc=$?
    case $rc in
      0) [[ $(printf '%s' "$line" | cut -f1) == "$(jq -r .bytes "$record")" ]] || result=1 ;;
      "$R2_NOT_FOUND") result=1 ;;
      *) result=2 ;;
    esac
  fi
  [[ $result == 2 ]] || printf '%s/%s\t%s\n' "$feed" "$k" "$result" >>"$work/confirmed"
  return "$result"
}

# newer_copy FEED KEY RECORD: 0 when a version of FEED other than KEY, not itself a prune
# candidate and not older than RECORD (the sort stamp; a tie counts, as the current and the new
# zip are archived in the same second when a feed sends no Last-Modified), is confirmed in R2
# (confirm_copy); 1 when none is; 2 when a read failed (not a 404). The versions looked at are
# those in the local archive (this build's) and those R2 lists.
newer_copy() {
  local feed=$1 k=$2 record=$3 other other_record ok rc
  {
    if [[ -d $archive/$feed ]]; then
      find "$archive/$feed" -mindepth 1 -maxdepth 1 -type f -name '*.json' -exec basename {} .json \;
    fi
    awk -F '\t' -v dir="sources/$feed/" 'index($1, dir) == 1 && $1 ~ /\.json$/ { k = substr($1, length(dir) + 1); print substr(k, 1, length(k) - 5) }' \
      "$work/listing"
  } | LC_ALL=C sort -u >"$work/others"
  while IFS= read -r other; do
    [[ $other =~ $plain && $other != "$k" ]] || continue
    awk -F '\t' -v f="$feed" -v k="$other" '$1 == f && $2 == k { found = 1 } END { exit !found }' "$work/candidates" && continue
    if [[ -f $archive/$feed/$other.json ]]; then
      other_record="$archive/$feed/$other.json"
    else
      other_record="$work/other.json"
      rc=0
      "$R2" get "sources/$feed/$other.json" "$other_record" || rc=$?
      case $rc in 0) ;; "$R2_NOT_FOUND") continue ;; *) return 2 ;; esac
    fi
    ok=$(jq -n --slurpfile d "$record" --slurpfile o "$other_record" "$STAMP"'
      ($o[0] | (.lastModified | type == "string") and (.archivedAt | type == "string"))
      and (($o[0] | stamp) >= ($d[0] | stamp))' 2>/dev/null) || ok=false
    [[ $ok == true ]] || continue
    rc=0
    confirm_copy "$feed" "$other" "$other_record" || rc=$?
    [[ $rc == 1 ]] || return "$rc"
  done <"$work/others"
  return 1
}

# guard: from the candidates, the plan of deletions: a version is deleted only when R2 holds a
# confirmed copy of its feed at least as new (newer_copy), and never when the live set
# (data/manifest.json) names it. Every read is done before any delete; a failed read (anything
# but a 404) keeps everything: returns 1 with the reason printed.
guard() {
  local feed k why rc etag kept=0
  rc=0
  "$R2" list sources/ >"$work/listing" || rc=$?
  [[ $rc -eq 0 ]] || { keep_all "cannot list sources/ (r2 exit $rc)"; return 1; }
  : >"$work/live"
  rc=0
  "$R2" get data/manifest.json "$work/live-manifest.json" || rc=$?
  case $rc in
    0)
      jq -e "$MANIFEST_CHECK" "$work/live-manifest.json" >/dev/null 2>&1 ||
        { keep_all "data/manifest.json is not a manifest these scripts accept"; return 1; }
      # Every version the live set names, as current or as an archived <feed>@<key8>: the feed
      # and the ETag (as JSON, so it stays one field). Sources in another shape would protect no
      # version, so they keep everything (an empty ETag, a feed sent without one, names none).
      jq -e '.sources | type == "object" and all(.[]; type == "array"
          and all(.[]; type == "object" and (.feed | type == "string") and (.etag | type == "string")))' \
        "$work/live-manifest.json" >/dev/null 2>&1 ||
        { keep_all "the sources of data/manifest.json are not a list of versions per timetable"; return 1; }
      jq -r '.sources[][] | select(.etag != "") | "\(.feed)\t\(.etag | @json)"' \
        "$work/live-manifest.json" >"$work/live" 2>/dev/null ||
        { keep_all "cannot read the sources of data/manifest.json"; return 1; }
      ;;
    "$R2_NOT_FOUND") log "no data/manifest.json: no live set to keep a version for" ;;
    *) keep_all "cannot read data/manifest.json (r2 exit $rc)"; return 1 ;;
  esac
  : >"$work/confirmed"
  : >"$work/plan"
  while IFS=$'\t' read -r feed k why; do
    rc=0
    "$R2" get "sources/$feed/$k.json" "$work/record.json" || rc=$?
    case $rc in
      0) ;;
      "$R2_NOT_FOUND") log "kept sources/$feed/$k.zip ($why): its record is no longer in R2"; kept=$((kept + 1)); continue ;;
      *) keep_all "cannot read sources/$feed/$k.json (r2 exit $rc)"; return 1 ;;
    esac
    if ! jq -e --arg feed "$feed" --arg key "$k" '.feed == $feed and .key == $key and (.etag | type == "string")
        and (.lastModified | type == "string") and (.archivedAt | type == "string")' "$work/record.json" >/dev/null 2>&1; then
      log "kept $feed/$k ($why): its record in R2 does not read as one"
      kept=$((kept + 1))
      continue
    fi
    etag=$(jq -r '.etag | @json' "$work/record.json") || die "cannot read sources/$feed/$k.json"
    if grep -Fxq -- "$feed"$'\t'"$etag" "$work/live"; then
      log "kept $feed/$k ($why): the live set was built from it"
      continue
    fi
    rc=0
    newer_copy "$feed" "$k" "$work/record.json" || rc=$?
    case $rc in
      0)
        printf 'sources/%s/%s.json\t%s\n' "$feed" "$k" "$why" >>"$work/plan"
        printf 'sources/%s/%s.zip\t%s\n' "$feed" "$k" "$why" >>"$work/plan"
        ;;
      1) log "kept $feed/$k ($why): no copy of $feed at least as new is confirmed in R2"; kept=$((kept + 1)) ;;
      *) keep_all "cannot read a newer copy of $feed in R2"; return 1 ;;
    esac
  done <"$work/candidates"
  if [[ $kept -gt 0 ]]; then
    summary "warning: kept $kept source versions that would have been pruned: no newer copy of their feed is confirmed in R2 (a failed upload?); the next publish tries again"
  fi
}

prune() {
  local oldest path end was_restored feed k count=0 why
  [[ -f $restored ]] || die "$restored is missing: run restore-state.sh first"
  if awk -F '\t' '$3 == 1' "$restored" | grep -q . && [[ ! -d $archive ]]; then
    die "$archive is missing, yet sources were restored into it: every record would look pruned; stopping"
  fi
  oldest=$(day_add "$today" -30) || die "cannot count back from $today"
  : >"$work/candidates"
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
    printf '%s\t%s\t%s\n' "$feed" "$k" "$why" >>"$work/candidates"
  done <"$restored"
  count=$(($(wc -l <"$work/candidates") * 2))
  if [[ $count -gt $max_deletions ]]; then
    die "the prune plan deletes $count objects, more than --max-deletions $max_deletions: nothing was deleted; check it with --dry-run"
  fi
  if [[ $count -eq 0 ]]; then
    log "pruned 0 source versions"
    return 0
  fi
  guard || return 0
  count=$(wc -l <"$work/plan" | tr -d ' ')
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

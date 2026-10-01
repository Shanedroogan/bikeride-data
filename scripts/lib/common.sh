# shellcheck shell=bash
# Shared by the publishing scripts (sourced, not run). Each script sets SCRIPT before sourcing.
# Bash 3.2 (macOS's /bin/bash runs publish-local.sh and rollback.sh): no associative arrays,
# no mapfile, and an empty array is expanded as ${a[@]+"${a[@]}"} under set -u.
#
# Exit statuses the scripts share: 0 done (or nothing to do, such as an active hold); 1 a
# failure; 64 usage.
#
# A value computed by $(...) is always assigned on its own line with "|| die": a die inside a
# command substitution ends only the subshell, and an empty time must never read as "old" (GC)
# or "past" (a hold).
set +x

readonly EX_USAGE=64
readonly R2_NOT_FOUND=10
SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
R2="$SCRIPTS_DIR/r2.sh"

log() { echo "$SCRIPT: $*" >&2; }
die() { echo "$SCRIPT: $1" >&2; exit "${2:-1}"; }
usage_error() { echo "$SCRIPT: $1 (see --help)" >&2; exit "$EX_USAGE"; }

# need_value OPTION ARGC: an option that takes a value has one.
need_value() { [[ $2 -ge 2 ]] || usage_error "$1 needs a value"; }

check_day() { [[ $2 =~ ^[0-9]{8}$ ]] || usage_error "$1 needs YYYYMMDD"; }
check_time() { [[ $2 =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || usage_error "$1 needs an ISO 8601 UTC time, e.g. 2026-10-07T12:00:00Z"; }
check_count() { [[ $2 =~ ^[1-9][0-9]*$ ]] || usage_error "$1 needs a positive integer"; }

need_tools() {
  local tool
  for tool in "$@"; do command -v "$tool" >/dev/null 2>&1 || die "needs $tool on PATH"; done
}

# summary LINE: one line for the run's summary: the GitHub step summary when there is one, and
# stderr always.
summary() {
  log "$1"
  if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then printf -- '- %s: %s\n' "$SCRIPT" "$1" >>"$GITHUB_STEP_SUMMARY"; fi
}

# --- Hashes, sizes, times ----------------------------------------------------------------------

sha256_of() {
  local hex
  if command -v sha256sum >/dev/null 2>&1; then hex=$(sha256sum "$1" | cut -d' ' -f1); else hex=$(shasum -a 256 "$1" | cut -d' ' -f1); fi
  [[ $hex =~ ^[0-9a-f]{64}$ ]] || die "cannot hash $1"
  printf '%s\n' "$hex"
}

md5_of() {
  local hex
  if command -v md5sum >/dev/null 2>&1; then hex=$(md5sum "$1" | cut -d' ' -f1); else hex=$(md5 -q "$1"); fi
  [[ $hex =~ ^[0-9a-f]{32}$ ]] || die "cannot hash $1"
  printf '%s\n' "$hex"
}

size_of() { wc -c <"$1" | tr -d ' '; }

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# epoch_of TIME: seconds since 1970 of an ISO 8601 UTC time, as these scripts write it
# (2026-10-07T12:00:00Z) or as the AWS CLI prints LastModified (2026-10-07T12:00:00+00:00, with
# or without fractional seconds). Fails on anything else.
epoch_of() {
  local text=$1 base
  [[ $text =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|\+00:00)$ ]] || die "unreadable time '$text'"
  base=${text:0:19}
  date -u -d "${base}Z" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%S' "$base" +%s 2>/dev/null || die "unreadable time '$text'"
}

iso_of_epoch() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }

# day_add YYYYMMDD N: the day N days later (N may be negative).
day_add() {
  local epoch
  epoch=$(epoch_of "${1:0:4}-${1:4:2}-${1:6:2}T12:00:00Z") || return 1
  date -u -d "@$((epoch + $2 * 86400))" +%Y%m%d 2>/dev/null || date -u -r "$((epoch + $2 * 86400))" +%Y%m%d
}

# The build day: today in New York, as bikeride-data all takes it.
today_new_york() { TZ=America/New_York date +%Y%m%d; }

# --- R2 ----------------------------------------------------------------------------------------

# r2_get KEY FILE: 0 got it, 10 not found. Any other failure (access denied, 5xx, the network)
# stops the script, with r2.sh's fixed line already printed: only a 404 means "not there".
r2_get() {
  local rc=0
  "$R2" get "$1" "$2" || rc=$?
  case $rc in
    0 | "$R2_NOT_FOUND") return "$rc" ;;
    *) die "cannot read $1 (r2 exit $rc); stopping" ;;
  esac
}

# r2_head_bytes KEY: prints the stored size; 10 not found; any other failure stops the script.
r2_head_bytes() {
  local rc=0 line
  line=$("$R2" head "$1") || rc=$?
  case $rc in
    0) printf '%s\n' "${line%%$'\t'*}" ;;
    "$R2_NOT_FOUND") return "$rc" ;;
    *) die "cannot HEAD $1 (r2 exit $rc); stopping" ;;
  esac
}

# r2_put FILE KEY: upload (r2.sh checks the size with a HEAD); any failure stops the script.
r2_put() { "$R2" put "$1" "$2" || die "upload of $2 failed; stopping"; }

r2_delete() { "$R2" delete "$1" || die "delete of $1 failed; stopping"; }

# r2_list PREFIX FILE: the listing ("<key>\t<bytes>\t<lastModified>" per line) into FILE.
r2_list() { "$R2" list "$1" >"$2" || die "cannot list $1; stopping"; }

# --- JSON read back from R2 ----------------------------------------------------------------------
# Every document read from R2 is checked before any value in it becomes a path, a key or a line
# of a public log: names are plain, digests are hex, times are ISO 8601 UTC.

# A published manifest (docs/publish.md): schema 1, a 16-hex setId, artifact names that are
# plain kebab-case words, 64-hex digests, positive integer sizes, the sidecar named
# trip-counts.json, carried names that are artifacts, statuses that are plain words.
# shellcheck disable=SC2016 # a jq program, not shell
MANIFEST_CHECK='
  def hex(n): type == "string" and test("^[0-9a-f]{" + (n|tostring) + "}$");
  def word: type == "string" and test("^[A-Za-z][A-Za-z0-9]{0,31}$");
  def iso: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
  type == "object" and .schema == 1 and (.setId | hex(16)) and (.generatedAt | iso)
  and ((.previousSetId // "0000000000000000") | hex(16))
  and (.buildDay | type == "string" and test("^[0-9]{8}$"))
  and (.artifacts | type == "object" and length > 0)
  and (.artifacts | to_entries | all(
        (.key | test("^[a-z][a-z0-9-]{0,31}$"))
        and (.value.sha | hex(64)) and (.value.rawSha256 | hex(64))
        and (.value.bytes | type == "number" and . > 0 and . == floor)))
  and (.tripCounts.file == "trip-counts.json") and (.tripCounts.sha256 | hex(64))
  and (.carriedForward | type == "array") and (. as $m | .carriedForward | all(. as $n | $m.artifacts | has($n)))
  and (.gate.status | word) and (.gate.checks | type == "array" and all((.name | word) and (.status | word)))
  and (.systems | type == "object" and (to_entries | all((.key | word) and (.value.status | word)
        and (.value.days | type == "number" and . == floor))))'
readonly MANIFEST_CHECK

# check_manifest FILE WHAT: stops unless FILE is a manifest as above.
check_manifest() {
  jq -e "$MANIFEST_CHECK" "$1" >/dev/null 2>&1 || die "$2 is not a manifest these scripts accept (schema, setId, names, digests or sizes); stopping"
}

# json_value FILTER FILE: one value with jq -r, from a document already checked.
json_value() { jq -r "$1" "$2"; }

# The dated copy's key: data/manifests/<generatedAt as YYYYMMDDTHHMMSSZ>-<setId>.json.
dated_manifest_key() {
  local at=$1 set_id=$2
  at=${at//-/}
  at=${at//:/}
  printf 'data/manifests/%s-%s.json\n' "$at" "$set_id"
}

# --- state.env -----------------------------------------------------------------------------------
# restore-state.sh writes it with printf, one KEY=value per line, no quotes. PREV_SET comes from
# R2, so readers take values with sed and check them; nothing sources the file.

state_value() { sed -n "s/^$2=//p" "$1" | tail -n 1; }

# read_state FILE: sets HOLD, FIRST_RUN, PREV_SET and BUILD_DAY, each checked.
read_state() {
  [[ -f $1 ]] || die "$1 is missing: run restore-state.sh first"
  HOLD=$(state_value "$1" HOLD)
  FIRST_RUN=$(state_value "$1" FIRST_RUN)
  PREV_SET=$(state_value "$1" PREV_SET)
  BUILD_DAY=$(state_value "$1" BUILD_DAY)
  [[ $HOLD =~ ^[01]$ && $FIRST_RUN =~ ^[01]$ ]] || die "$1: HOLD and FIRST_RUN must each be 0 or 1"
  [[ -z $PREV_SET || $PREV_SET =~ ^[0-9a-f]{16}$ ]] || die "$1: PREV_SET is not a setId"
  [[ $BUILD_DAY =~ ^[0-9]{8}$ ]] || die "$1: BUILD_DAY is not YYYYMMDD"
  if [[ $HOLD == 0 ]]; then
    if [[ $FIRST_RUN == 1 && -n $PREV_SET ]] || [[ $FIRST_RUN == 0 && -z $PREV_SET ]]; then
      die "$1: FIRST_RUN and PREV_SET disagree"
    fi
  fi
}

# --- The hold ------------------------------------------------------------------------------------

# hold_active NOW: 0 when data/hold.json holds publishing at NOW (it has no until, or its until
# is later), with HOLD_TEXT set to a line safe for a public log; 1 when there is no hold or it
# has expired. A hold that cannot be read or parsed stops the script: a typo in a hand-written
# hold must fail loudly, never publish.
hold_active() {
  local now=$1 file rc=0 reason until until_epoch now_epoch
  file=$(mktemp "${TMPDIR:-/tmp}/hold.XXXXXX")
  r2_get data/hold.json "$file" || rc=$?
  if [[ $rc -eq $R2_NOT_FOUND ]]; then
    rm -f "$file"
    return 1
  fi
  if ! jq -e 'type == "object" and (.reason | type == "string")
      and ((.until // "2000-01-01T00:00:00Z") | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' \
    "$file" >/dev/null 2>&1; then
    rm -f "$file"
    die "data/hold.json is not {reason, until}: fix or remove it by hand; stopping"
  fi
  # Printable ASCII only, at most 200 characters: the reason reaches a public log.
  reason=$(jq -r '.reason' "$file" | LC_ALL=C tr -cd '[:print:]' | cut -c 1-200)
  until=$(jq -r '.until // ""' "$file")
  rm -f "$file"
  if [[ -n $until ]]; then
    until_epoch=$(epoch_of "$until") || die "data/hold.json: unreadable until; stopping"
    now_epoch=$(epoch_of "$now") || die "unreadable time '$now'"
    if [[ $until_epoch -le $now_epoch ]]; then
      log "data/hold.json expired at $until; publishing as usual"
      return 1
    fi
  fi
  # shellcheck disable=SC2034 # read by the callers
  HOLD_TEXT="publishing is on hold (data/hold.json): ${reason:-no reason given}${until:+, until $until}"
  return 0
}

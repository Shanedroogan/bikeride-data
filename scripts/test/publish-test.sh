#!/usr/bin/env bash
# Tests of the publishing scripts (restore-state, build-set, publish-set, sync-sources, gc-data,
# rollback, publish-local, set-summary) against scripts/test/fake-aws, with a stand-in
# bikeride-data. Nothing here reaches the network or a real bucket (scripts/test/harness.sh).
#
#   scripts/test/publish-test.sh
#
# Sets are made up: each artifact is a line of text, xz-compressed, with a manifest, sidecar and
# heartbeat shaped as bikeride-data writes them.
# shellcheck source-path=SCRIPTDIR source=harness.sh
. "$(dirname "$0")/harness.sh"
scripts="$repo/scripts"
command -v xz >/dev/null || { echo "${0##*/}: needs xz" >&2; exit 1; }
command -v jq >/dev/null || { echo "${0##*/}: needs jq" >&2; exit 1; }

DAY=20261007
NOW=2026-10-07T12:00:00Z
CORE="streets stations tt-subway tt-bus tt-lirr tt-ferry tt-path config links"

sha() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
size() { wc -c <"$1" | tr -d ' '; }
# An object's LastModified, in UTC (touch reads the local zone otherwise).
age() { TZ=UTC touch -t "$1" "${@:2}"; }

# make_set OUT AT PREV TAG BUILT [CARRIED]: a set in OUT generated at AT, built on the manifest
# PREV ("-" for none). BUILT names get fresh content (TAG makes it differ between sets); CARRIED
# names are copied from PREV's entries. Sets SET_ID.
make_set() {
  local out=$1 at=$2 prev=$3 tag=$4 built=$5 carried=${6:-} name arts='{}' sidecar_sha
  mkdir -p "$out"
  for name in $built; do
    printf '%s %s\n' "$name" "$tag" >"$out/$name.bin"
    xz -c "$out/$name.bin" >"$out/$name.bin.xz"
    arts=$(jq -c --arg n "$name" --arg sha "$(sha "$out/$name.bin.xz")" --argjson bytes "$(size "$out/$name.bin.xz")" \
      --arg raw "$(sha "$out/$name.bin")" \
      '. + {($n): {sha: $sha, bytes: $bytes, rawBytes: 1, rawSha256: $raw, formatVersion: 1, dataVersion: "test", builtAgainst: {}}}' <<<"$arts")
  done
  for name in $carried; do
    arts=$(jq -c --arg n "$name" --slurpfile p "$prev" '. + {($n): $p[0].artifacts[$n]}' <<<"$arts")
  done
  jq -j 'to_entries | sort_by(.key) | map("\(.key)\t\(.value.sha)\n") | join("")' <<<"$arts" >"$out/.ids"
  SET_ID=$(sha "$out/.ids" | cut -c 1-16)
  rm -f "$out/.ids"
  jq -n -cj --arg id "$SET_ID" --arg day "$DAY" '{schema: 1, setId: $id, buildDay: $day, systems: {subway: {"2026-10-07": 100}}}' \
    >"$out/trip-counts.json"
  sidecar_sha=$(sha "$out/trip-counts.json")
  local previous=null
  [[ $prev == - ]] || previous=$(jq '.setId' "$prev")
  jq -n -cjS --arg id "$SET_ID" --arg at "$at" --arg day "$DAY" --argjson arts "$arts" --argjson prev "$previous" \
    --arg sidecar "$sidecar_sha" --arg carried "$carried" '
    {schema: 1, setId: $id, generatedAt: $at, tool: "bikeride-data test", buildDay: $day,
     carriedForward: ($carried | split(" ") | map(select(. != "")) | sort), artifacts: $arts,
     coverage: {subway: ["2026-10-07"]},
     systems: {subway: {artifact: "tt-subway", first: "2026-10-06", last: "2026-10-31", dates: 26, days: 25, status: "ok"}},
     sources: {}, gate: {status: "pass", checks: [{name: "artifacts", status: "pass", warnings: 0}, {name: "tripCounts", status: "skipped", warnings: 1}]},
     tripCounts: {file: "trip-counts.json", sha256: $sidecar}}
    + (if $prev == null then {} else {previousSetId: $prev} end)' >"$out/manifest.json"
  jq -n -cj --arg id "$SET_ID" --arg at "$at" '{checkedAt: $at, lastTimetableSuccessAt: $at, setId: $id, job: "timetables", result: "built"}' \
    >"$out/heartbeat.json"
}

# install_set DIR [dated-only]: puts DIR's blobs, sidecar and dated copy into the bucket, and
# (unless dated-only) makes it the current set.
install_set() {
  local dir=$1 file at id
  mkdir -p "$bucket/data/blobs" "$bucket/data/trip-counts" "$bucket/data/manifests"
  for file in "$dir"/*.bin.xz; do
    [[ -e $file ]] || continue
    cp "$file" "$bucket/data/blobs/$(sha "$file").xz"
  done
  cp "$dir/trip-counts.json" "$bucket/data/trip-counts/$(sha "$dir/trip-counts.json").json"
  at=$(jq -r .generatedAt "$dir/manifest.json")
  id=$(jq -r .setId "$dir/manifest.json")
  at=${at//-/}
  cp "$dir/manifest.json" "$bucket/data/manifests/${at//:/}-$id.json"
  if [[ ${2:-} != dated-only ]]; then
    cp "$dir/manifest.json" "$bucket/data/manifest.json"
    cp "$dir/heartbeat.json" "$bucket/data/heartbeat.json"
  fi
}

reset_bucket() { rm -rf "$bucket"; mkdir -p "$bucket"; }
put_hold() { mkdir -p "$bucket/data"; printf '%s' "$1" >"$bucket/data/hold.json"; }
current_set() { jq -r .setId "$bucket/data/manifest.json"; }
# The order of the logged calls, one "<op> <key>" per line.
call_order() { sed -n 's/.* s3api \([a-z-]*\) --bucket test-bucket --[a-z]* \([^ ]*\).*/\1 \2/p' "$FAKE_AWS_LOG"; }
line_of() { call_order | grep -n -- "$1" | head -n 1 | cut -d: -f1; }

restore() { run "$scripts/restore-state.sh" --today "$DAY" --now "$NOW" "$@"; }
publish() { run "$scripts/publish-set.sh" --now "$NOW" "$@"; }

# A stand-in bikeride-data: records its arguments, copies FAKE_BRD_SET into --out, writes the
# reports publish-local.sh reads, and exits FAKE_BRD_STATUS. A FAKE_BRD_WARNING of "built without
# entrances" with --strict-sources exits 1, as timetables (and so all) does then.
cat >"$work/bin/bikeride-data" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_BRD_LOG"
out='' strict=0
while [[ $# -gt 0 ]]; do
  case $1 in --out) out=$2; shift ;; --strict-sources) strict=1 ;; esac
  shift
done
[[ -n $out ]] || exit 64
mkdir -p "$out" "$(dirname "$out")/reports"
if [[ -n ${FAKE_BRD_SET:-} ]]; then cp "$FAKE_BRD_SET"/* "$out"/; fi
printf '{"warnings":["%s"]}\n' "${FAKE_BRD_WARNING:-none}" >"$(dirname "$out")/reports/timetables.json"
printf '{"sanity":[{"name":"x","pass":%s}]}\n' "${FAKE_BRD_SANITY:-true}" >"$(dirname "$out")/reports/streets.json"
if [[ $strict == 1 && ${FAKE_BRD_WARNING:-} == *"built without entrances"* ]]; then exit 1; fi
exit "${FAKE_BRD_STATUS:-0}"
FAKE
chmod +x "$work/bin/bikeride-data"
export BIKERIDE_DATA="$work/bin/bikeride-data" FAKE_BRD_LOG="$work/brd.log"

# The base fixture: set A, published, and set B built on it by a timetables run (streets,
# stations and flows carried).
make_set "$work/setA" 2026-10-06T07:15:00Z - a "$CORE flows"
SET_A=$SET_ID
make_set "$work/setB" 2026-10-07T07:15:00Z "$work/setA/manifest.json" b "tt-subway tt-bus tt-lirr tt-ferry tt-path config links" \
  "streets stations flows"
SET_B=$SET_ID
# The timetables run restores streets and stations into its data directory, and their blobs are
# then built-not-carried in the manifest bikeride-data writes; the fixture keeps them carried,
# which publish-set treats the same way minus the PUT.

fresh() { # fresh NAME: a new work directory for one run
  rm -rf "$work/run-$1"
  mkdir -p "$work/run-$1"
  printf '%s' "$work/run-$1"
}

# --- Usage ---------------------------------------------------------------------------------------

begin "every script answers --help and refuses an unknown argument, before any call"
for script in restore-state.sh publish-set.sh sync-sources.sh gc-data.sh publish-local.sh rollback.sh build-set.sh; do
  run "$scripts/$script" --help; expect_status 0
  [[ $out == USAGE:* ]] || fail "$script --help: $out"
  run "$scripts/$script" --bogus; expect_status 64
done
run "$scripts/restore-state.sh" --job gc --prev p --sources s --data d; expect_status 64
run "$scripts/restore-state.sh" --job timetables --prev p --sources s --data d --today 2026-10-07; expect_status 64
run "$scripts/restore-state.sh" --blobs-only --job timetables --prev p --data d; expect_status 64
run "$scripts/publish-set.sh" --data d; expect_status 64
run "$scripts/sync-sources.sh" prune --sources s; expect_status 64
run "$scripts/sync-sources.sh" aux --sources s --files streets; expect_status 64
run "$scripts/gc-data.sh" --max-deletions 0; expect_status 64
run "$scripts/gc-data.sh" --now yesterday; expect_status 64
run "$scripts/rollback.sh" 3b0f7ece25409da6; expect_status 64
run "$scripts/rollback.sh" 3B0F7ECE25409DA6 --reason x; expect_status 64
run "$scripts/rollback.sh" 3b0f7ece25409da6 3b0f7ece25409da7 --reason x; expect_status 64
run "$scripts/rollback.sh" 3b0f7ece25409da6 --reason "$(printf 'bad\tstops')"; expect_status 64
run "$scripts/rollback.sh" 3b0f7ece25409da6 --reason x --until 2026-10-07T00:00:00Z --now "$NOW"; expect_status 64
run "$scripts/build-set.sh" --job timetables --prev p --data d --sources s --accept-trip-count-change 'subway;id'; expect_status 64
printf 'R2_BUCKET=x\n' >"$work/files/test.env"
run "$scripts/publish-local.sh" --work "$work/files" --env "$work/files/test.env"; expect_status 64
run "$scripts/publish-local.sh" --work "$work/new" --env "$work/files/test.env" --first; expect_status 64
expect_no_calls
[[ ! -e $work/new ]] || fail "publish-local.sh created its work directory"

# --- restore-state.sh ----------------------------------------------------------------------------

begin "restore: an empty bucket is a first run only with --allow-first-run (404 on the manifest)"
reset_bucket
d=$(fresh r1)
restore --job timetables --prev "$d/prev" --sources "$d/sources" --data "$d/data"; expect_status 1
expect_err "publish-local.sh --first"
[[ ! -e $d/prev/state.env ]] || fail "a refused first run wrote state.env"
d=$(fresh r1b)
restore --job timetables --prev "$d/prev" --sources "$d/sources" --data "$d/data" --allow-first-run; expect_status 0
[[ $(cat "$d/prev/state.env") == $'HOLD=0\nFIRST_RUN=1\nPREV_SET=\nBUILD_DAY=20261007' ]] || fail "state.env: $(cat "$d/prev/state.env")"
[[ ! -e $d/prev/manifest.json && ! -e $d/data/streets.bin ]] || fail "a first run restored something"
expect_call "get-object --bucket test-bucket --key data/manifest.json"

begin "restore: 403 or 5xx on the manifest fails, never a first run"
for what in 403 500 network; do
  d=$(fresh "r2$what")
  FAKE_AWS_FAIL="get-object:data/manifest.json:$what" restore --job timetables --prev "$d/prev" --sources "$d/sources" \
    --data "$d/data" --allow-first-run
  expect_status 1
  expect_err "cannot read data/manifest.json"
  [[ ! -e $d/prev/state.env ]] || fail "$what: state.env written"
done

begin "restore: the previous set, its heartbeat, the sidecar by sha, and streets and stations for timetables"
reset_bucket
install_set "$work/setA"
d=$(fresh r3)
restore --job timetables --prev "$d/prev" --sources "$d/sources" --data "$d/data"; expect_status 0
[[ $(cat "$d/prev/state.env") == $'HOLD=0\nFIRST_RUN=0\nPREV_SET='"$SET_A"$'\nBUILD_DAY=20261007' ]] || fail "state.env: $(cat "$d/prev/state.env")"
cmp -s "$d/prev/manifest.json" "$work/setA/manifest.json" || fail "manifest"
cmp -s "$d/prev/heartbeat.json" "$work/setA/heartbeat.json" || fail "heartbeat"
cmp -s "$d/prev/trip-counts.json" "$work/setA/trip-counts.json" || fail "sidecar"
expect_call "get-object --bucket test-bucket --key data/trip-counts/$(sha "$work/setA/trip-counts.json").json"
for name in streets stations; do
  cmp -s "$d/data/$name.bin.xz" "$work/setA/$name.bin.xz" || fail "$name.bin.xz"
  cmp -s "$d/data/$name.bin" "$work/setA/$name.bin" || fail "$name.bin"
done
[[ $(find "$d/data" -type f | wc -l | tr -d ' ') == 4 ]] || fail "data holds more than streets and stations: $(ls "$d/data")"
d=$(fresh r3s)
restore --job streets --prev "$d/prev" --sources "$d/sources" --data "$d/data"; expect_status 0
[[ -z $(ls -A "$d/data") ]] || fail "a streets run restored blobs: $(ls "$d/data")"
d=$(fresh r3f)
mkdir -p "$d/data" && cp "$work/setA/flows.bin" "$d/data/"
: >"$FAKE_AWS_LOG"
restore --job flows --prev "$d/prev" --sources "$d/sources" --data "$d/data"; expect_status 0
expect_no_call "list-objects-v2"
[[ ! -e $d/sources ]] || fail "a flows run restored sources"

begin "restore: a sidecar, blob or raw file that does not match its sha fails"
d=$(fresh r4)
cp "$bucket/data/trip-counts/$(sha "$work/setA/trip-counts.json").json" "$work/files/sidecar.keep"
printf '{}' >"$bucket/data/trip-counts/$(sha "$work/setA/trip-counts.json").json"
restore --job streets --prev "$d/prev" --sources "$d/sources" --data "$d/data"; expect_status 1
expect_err "sha256"
cp "$work/files/sidecar.keep" "$bucket/data/trip-counts/$(sha "$work/setA/trip-counts.json").json"
streets_blob="$bucket/data/blobs/$(sha "$work/setA/streets.bin.xz").xz"
cp "$streets_blob" "$work/files/streets.keep"
printf 'streets other\n' | xz -c >"$streets_blob"
d=$(fresh r4b)
restore --job timetables --prev "$d/prev" --sources "$d/sources" --data "$d/data"; expect_status 1
cp "$work/files/streets.keep" "$streets_blob"
rm "$streets_blob"
d=$(fresh r4c)
restore --job timetables --prev "$d/prev" --sources "$d/sources" --data "$d/data"; expect_status 1
expect_err "is missing"
cp "$work/files/streets.keep" "$streets_blob"

begin "restore: a flows.bin in the data directory fails timetables and streets"
for job in timetables streets; do
  d=$(fresh "r5$job")
  mkdir -p "$d/data" && cp "$work/setA/flows.bin.xz" "$d/data/"
  restore --job "$job" --prev "$d/prev" --sources "$d/sources" --data "$d/data"; expect_status 1
  expect_err "flows never reaches the public runner"
done

begin "restore: a non-empty --prev is refused"
d=$(fresh r6)
mkdir -p "$d/prev" && touch "$d/prev/manifest.json"
restore --job streets --prev "$d/prev" --sources "$d/sources" --data "$d/data"; expect_status 1
expect_no_calls

begin "the hold: active (no until, or until later) stops the run with exit 0 before the manifest is read"
export GITHUB_STEP_SUMMARY="$work/summary.md"
: >"$GITHUB_STEP_SUMMARY"
put_hold "$(printf '{"reason":"bad stops\\u0007 on the A","until":"2026-10-08T00:00:00Z"}')"
d=$(fresh h1)
restore --job timetables --prev "$d/prev" --sources "$d/sources" --data "$d/data"; expect_status 0
[[ $(sed -n 's/^HOLD=//p' "$d/prev/state.env") == 1 ]] || fail "HOLD not 1"
expect_no_call "data/manifest.json"
grep -q "on hold (data/hold.json): bad stops on the A, until 2026-10-08T00:00:00Z" "$GITHUB_STEP_SUMMARY" || fail "summary: $(cat "$GITHUB_STEP_SUMMARY")"
LC_ALL=C grep -q "$(printf '\007')" "$GITHUB_STEP_SUMMARY" && fail "a control character reached the summary"
put_hold '{"reason":"by hand"}'
d=$(fresh h2)
restore --job timetables --prev "$d/prev" --sources "$d/sources" --data "$d/data"; expect_status 0
[[ $(sed -n 's/^HOLD=//p' "$d/prev/state.env") == 1 ]] || fail "a hold with no until is not active"
unset GITHUB_STEP_SUMMARY

begin "the hold: an expired one is ignored; an unreadable one fails; a 403 on it fails"
put_hold '{"reason":"old","until":"2026-10-07T11:59:59Z"}'
d=$(fresh h3)
restore --job streets --prev "$d/prev" --sources "$d/sources" --data "$d/data"; expect_status 0
[[ $(sed -n 's/^HOLD=//p' "$d/prev/state.env") == 0 ]] || fail "an expired hold held"
for bad in '{"until":"2026-10-08T00:00:00Z"}' '{"reason":"x","until":"tomorrow"}' 'not json'; do
  put_hold "$bad"
  d=$(fresh h4)
  restore --job streets --prev "$d/prev" --sources "$d/sources" --data "$d/data"; expect_status 1
  expect_err "data/hold.json is not {reason, until}"
done
rm -f "$bucket/data/hold.json"
d=$(fresh h5)
FAKE_AWS_FAIL="get-object:data/hold.json:403" restore --job streets --prev "$d/prev" --sources "$d/sources" --data "$d/data"
expect_status 1
expect_err "cannot read data/hold.json"

# Source records: <feed>/<key>.zip with its record, as GTFSSourceArchive writes them.
make_record() { # DIR FEED KEY CALENDAR_END CONTENT
  mkdir -p "$1/$2"
  printf '%s' "$5" >"$1/$2/$3.zip"
  jq -n -cj --arg feed "$2" --arg key "$3" --arg end "$4" --arg sha "$(sha "$1/$2/$3.zip")" --argjson bytes "$(size "$1/$2/$3.zip")" \
    '{feed: $feed, key: $key, url: "https://example.invalid/x.zip", etag: $key, lastModified: "", sha256: $sha, bytes: $bytes,
      archivedAt: "2026-10-01T00:00:00Z", coverage: []} + (if $end == "-" then {} else {calendarStart: "20260901", calendarEnd: $end} end)' \
    >"$1/$2/$3.json"
}

begin "restore: source records still in use, each zip checked; aux files stamped 1970; the list for prune"
make_record "$bucket/sources" gtfs_subway cur 20261031 "subway current"
make_record "$bucket/sources" gtfs_subway yday 20261006 "subway ending yesterday"
make_record "$bucket/sources" gtfs_bus old 20261005 "bus ended"
make_record "$bucket/sources" gtfs_ferry nocal - "ferry with no calendar"
make_record "$bucket/sources" gtfs_path torn 20261231 "path torn"
rm "$bucket/sources/gtfs_path/torn.zip"
mkdir -p "$bucket/sources/aux"
printf 'entrances\n' >"$bucket/sources/aux/subway-entrances.csv"
d=$(fresh s1)
restore --job timetables --prev "$d/prev" --sources "$d/sources" --data "$d/data"; expect_status 0
a="$d/sources/gtfs/archive"
for kept in gtfs_subway/cur gtfs_subway/yday gtfs_ferry/nocal; do
  cmp -s "$a/$kept.zip" "$bucket/sources/$kept.zip" || fail "$kept.zip not restored"
  cmp -s "$a/$kept.json" "$bucket/sources/$kept.json" || fail "$kept.json not restored"
done
[[ ! -e $a/gtfs_bus/old.zip && ! -e $a/gtfs_path/torn.json ]] || fail "an ended or torn record was restored"
expect_no_call "get-object --bucket test-bucket --key sources/gtfs_bus/old.zip"
[[ $(sort "$d/prev/sources-restored.txt") == "$(printf 'gtfs_bus/old\t20261005\t0\ngtfs_ferry/nocal\t-\t1\ngtfs_subway/cur\t20261031\t1\ngtfs_subway/yday\t20261006\t1')" ]] ||
  fail "sources-restored.txt: $(cat "$d/prev/sources-restored.txt")"
cmp -s "$d/sources/nyc/subway-entrances.csv" "$bucket/sources/aux/subway-entrances.csv" || fail "entrances not restored"
[[ -z $(find "$d/sources/nyc/subway-entrances.csv" -newermt '1971-01-01' 2>/dev/null || echo x) ]] ||
  fail "the entrances copy is not stamped 1970: $(ls -l "$d/sources/nyc/subway-entrances.csv")"
[[ ! -e $d/sources/nyc/borough-boundaries-water-included.geojson ]] || fail "boundaries appeared"

mtime() { if stat -c %Y "$1" 2>/dev/null; then :; else stat -f %m "$1"; fi; }

begin "restore: both aux files to the builder's paths, at 1970-01-01 UTC, without stale sidecars; a local copy is kept"
printf 'boundaries\n' >"$bucket/sources/aux/borough-boundaries.geojson"
for job in timetables streets; do
  d=$(fresh s1$job)
  mkdir -p "$d/sources/nyc"
  # Sidecars left from another copy: an old ETag would get a 304 and keep the restored copy.
  printf '"old"' >"$d/sources/nyc/subway-entrances.csv.etag"
  printf '{}' >"$d/sources/nyc/borough-boundaries-water-included.geojson.source.json"
  restore --job "$job" --prev "$d/prev" --sources "$d/sources" --data "$d/data"; expect_status 0
  for pair in "subway-entrances.csv subway-entrances.csv" "borough-boundaries.geojson borough-boundaries-water-included.geojson"; do
    file="$d/sources/nyc/${pair#* }"
    cmp -s "$file" "$bucket/sources/aux/${pair%% *}" || fail "$job: ${pair#* } not restored from sources/aux/${pair%% *}"
    [[ $(mtime "$file") == 0 ]] || fail "$job: ${pair#* } is stamped $(mtime "$file"), not 0 (1970-01-01 UTC)"
    [[ ! -e $file.etag && ! -e $file.source.json ]] || fail "$job: a stale sidecar of ${pair#* } survived"
  done
done
d=$(fresh s1kept)
mkdir -p "$d/sources/nyc"
printf 'local entrances\n' >"$d/sources/nyc/subway-entrances.csv"
printf '"local"' >"$d/sources/nyc/subway-entrances.csv.etag"
age 202609300000 "$d/sources/nyc/subway-entrances.csv"
before=$(mtime "$d/sources/nyc/subway-entrances.csv")
: >"$FAKE_AWS_LOG"
restore --job timetables --prev "$d/prev" --sources "$d/sources" --data "$d/data"; expect_status 0
[[ $(cat "$d/sources/nyc/subway-entrances.csv") == "local entrances" ]] || fail "the local copy was replaced"
[[ $(mtime "$d/sources/nyc/subway-entrances.csv") == "$before" && -f $d/sources/nyc/subway-entrances.csv.etag ]] ||
  fail "the local copy's time stamp or ETag changed"
expect_no_call "get-object --bucket test-bucket --key sources/aux/subway-entrances.csv"
expect_call "get-object --bucket test-bucket --key sources/aux/borough-boundaries.geojson"
rm "$bucket/sources/aux/borough-boundaries.geojson"

begin "restore --job flows: the previous set's documents only; no sources/ and no blobs (flows.yml)"
d=$(fresh flows1)
mkdir -p "$d/data"
printf 'flows from the private runner\n' >"$d/data/flows.bin"
restore --job flows --prev "$d/prev" --sources "$d/sources" --data "$d/data"; expect_status 0
cmp -s "$d/prev/manifest.json" "$bucket/data/manifest.json" || fail "manifest not restored"
cmp -s "$d/prev/heartbeat.json" "$bucket/data/heartbeat.json" || fail "heartbeat not restored"
[[ -f $d/prev/trip-counts.json ]] || fail "the sidecar was not restored"
[[ $(sed -n 's/^PREV_SET=//p' "$d/prev/state.env") == "$(current_set)" ]] || fail "state.env: $(cat "$d/prev/state.env")"
expect_no_call "--prefix sources/"
expect_no_call "--key sources/"
expect_no_call "--key data/blobs/"
[[ ! -e $d/prev/sources-restored.txt && ! -e $d/sources ]] || fail "flows restored sources"
[[ ! -e $d/data/streets.bin && ! -e $d/data/stations.bin ]] || fail "flows restored blobs"
[[ -f $d/data/flows.bin ]] || fail "the flows.bin in --data was touched"

begin "restore: a source zip that does not match its record fails"
printf 'tampered' >"$bucket/sources/gtfs_subway/cur.zip"
d=$(fresh s2)
restore --job streets --prev "$d/prev" --sources "$d/sources" --data "$d/data"; expect_status 1
expect_err "sources/gtfs_subway/cur.zip"
printf 'subway current' >"$bucket/sources/gtfs_subway/cur.zip"

begin "restore --blobs-only: the streets fallback replaces what the failed build left"
d=$(fresh b1)
restore --job streets --prev "$d/prev" --sources "$d/sources" --data "$d/data"; expect_status 0
printf 'half built' >"$d/data/streets.bin"
printf 'half built' >"$d/data/stations.bin.xz"
run "$scripts/restore-state.sh" --blobs-only --prev "$d/prev" --data "$d/data"; expect_status 0
cmp -s "$d/data/streets.bin" "$work/setA/streets.bin" || fail "streets not restored"
cmp -s "$d/data/stations.bin.xz" "$work/setA/stations.bin.xz" || fail "stations not restored"

# --- build-set.sh --------------------------------------------------------------------------------

begin "build-set: a timetables run builds on the previous set, requires flows, carries streets and stations"
d=$(fresh m1)
restore --job timetables --prev "$d/prev" --sources "$d/sources" --data "$d/data"; expect_status 0
: >"$FAKE_BRD_LOG"
FAKE_BRD_SET="$work/setB" run "$scripts/build-set.sh" --job timetables --prev "$d/prev" --data "$d/data" --sources "$d/sources" \
  --accept-trip-count-change subway,path
expect_status 0
[[ $(cat "$FAKE_BRD_LOG") == "all --out $d/data --sources $d/sources --today 20261007 --strict-sources --job timetables --skip streets,stations,flows --previous $d/prev/manifest.json --require-flows --accept-trip-count-change subway,path" ]] ||
  fail "arguments: $(cat "$FAKE_BRD_LOG")"

begin "build-set: streets after the streets step; the fallback builds as timetables"
: >"$FAKE_BRD_LOG"
FAKE_BRD_SET="$work/setB" run "$scripts/build-set.sh" --job streets --prev "$d/prev" --data "$d/data" --sources "$d/sources"
expect_status 0
[[ $(cat "$FAKE_BRD_LOG") == *"--job streets --skip streets,flows --previous $d/prev/manifest.json --require-flows" ]] || fail "streets: $(cat "$FAKE_BRD_LOG")"
: >"$FAKE_BRD_LOG"
FAKE_BRD_SET="$work/setB" run "$scripts/build-set.sh" --job streets-restored --prev "$d/prev" --data "$d/data" --sources "$d/sources"
expect_status 0
[[ $(cat "$FAKE_BRD_LOG") == *"--job timetables --skip streets,stations,flows --previous"* ]] || fail "fallback: $(cat "$FAKE_BRD_LOG")"
d2=$(fresh m1b)
mkdir -p "$d2/prev" && cp "$d/prev/state.env" "$d2/prev/"
run "$scripts/build-set.sh" --job streets --prev "$d2/prev" --data "$d2/data" --sources "$d2/sources"; expect_status 1
expect_err "streets.bin is missing"

begin "build-set: a failed build, a flows.bin or a subway without entrances (--strict-sources) is not publishable"
FAKE_BRD_STATUS=3 run "$scripts/build-set.sh" --job timetables --prev "$d/prev" --data "$d/data" --sources "$d/sources"
expect_status 3
FAKE_BRD_SET="$work/setA" run "$scripts/build-set.sh" --job timetables --prev "$d/prev" --data "$d/data" --sources "$d/sources"
expect_status 1
expect_err "flows never reaches the public runner"
rm -f "$d/data/flows.bin" "$d/data/flows.bin.xz"
for job in timetables streets streets-restored; do
  : >"$FAKE_BRD_LOG"
  FAKE_BRD_WARNING="subway entrances unavailable (offline); built without entrances" FAKE_BRD_SET="$work/setB" \
    run "$scripts/build-set.sh" --job "$job" --prev "$d/prev" --data "$d/data" --sources "$d/sources"
  expect_status 1
  expect_err "stopped with status 1"
  [[ $(cat "$FAKE_BRD_LOG") == *" --strict-sources "* ]] || fail "$job: no --strict-sources: $(cat "$FAKE_BRD_LOG")"
done

begin "build-set: a held run builds nothing"
mkdir -p "$work/held" && printf 'HOLD=1\nFIRST_RUN=0\nPREV_SET=\nBUILD_DAY=20261007\n' >"$work/held/state.env"
: >"$FAKE_BRD_LOG"
run "$scripts/build-set.sh" --job timetables --prev "$work/held" --data "$d/data" --sources "$d/sources"; expect_status 1
[[ ! -s $FAKE_BRD_LOG ]] || fail "bikeride-data ran"

# --- The first-run dry run (I1 on an empty bucket) -----------------------------------------------

make_set "$work/setFirst" 2026-10-07T07:15:00Z - first "$CORE"
begin "first run, dry: restore writes FIRST_RUN=1; the build has no --previous or --require-flows; nothing is written"
reset_bucket
d=$(fresh f1)
restore --job timetables --prev "$d/prev" --sources "$d/sources" --data "$d/data" --allow-first-run; expect_status 0
: >"$FAKE_BRD_LOG"
FAKE_BRD_SET="$work/setFirst" run "$scripts/build-set.sh" --job timetables --prev "$d/prev" --data "$d/data" --sources "$d/sources" --dry-run
expect_status 0
[[ $(cat "$FAKE_BRD_LOG") == "all --out $d/data --sources $d/sources --today 20261007 --strict-sources --job timetables --skip flows" ]] ||
  fail "arguments: $(cat "$FAKE_BRD_LOG")"
publish --data "$d/data" --prev "$d/prev" --no-flows-upload --dry-run; expect_status 0
expect_err "[dry run] set $SET_ID would be published (previous none)"
expect_no_call "put-object"
expect_no_call "delete-object"
run "$scripts/gc-data.sh" --dry-run --now "$NOW"; expect_status 0
expect_err "nothing to collect"
[[ -z $(find "$bucket" -type f) ]] || fail "the bucket is not empty: $(find "$bucket" -type f)"

begin "first run, dry, streets: no --previous or --require-flows, streets skipped; the fallback is refused"
reset_bucket
d=$(fresh f2)
restore --job streets --prev "$d/prev" --sources "$d/sources" --data "$d/data" --allow-first-run; expect_status 0
[[ $(sed -n 's/^FIRST_RUN=//p' "$d/prev/state.env") == 1 ]] || fail "FIRST_RUN not 1"
# What the streets step built.
mkdir -p "$d/data" && printf 'streets first\n' >"$d/data/streets.bin"
: >"$FAKE_BRD_LOG"
FAKE_BRD_SET="$work/setFirst" run "$scripts/build-set.sh" --job streets --prev "$d/prev" --data "$d/data" --sources "$d/sources" --dry-run
expect_status 0
[[ $(cat "$FAKE_BRD_LOG") == "all --out $d/data --sources $d/sources --today 20261007 --strict-sources --job streets --skip streets,flows" ]] ||
  fail "arguments: $(cat "$FAKE_BRD_LOG")"
: >"$FAKE_BRD_LOG"
FAKE_BRD_SET="$work/setFirst" run "$scripts/build-set.sh" --job streets-restored --prev "$d/prev" --data "$d/data" --sources "$d/sources" --dry-run
expect_status 1
expect_err "no previous set to fall back to"
[[ ! -s $FAKE_BRD_LOG ]] || fail "bikeride-data ran"
expect_no_call "put-object"

begin "first run, real: the build refuses it (and restore without --allow-first-run already did)"
: >"$FAKE_BRD_LOG"
FAKE_BRD_SET="$work/setFirst" run "$scripts/build-set.sh" --job timetables --prev "$d/prev" --data "$d/data" --sources "$d/sources"
expect_status 1
expect_err "only as a dry run"
[[ ! -s $FAKE_BRD_LOG ]] || fail "bikeride-data ran"

# --- publish-set.sh ------------------------------------------------------------------------------

# A run: restore against the bucket as it is, then the set in SETDIR as what bikeride-data built.
prepare_run() { # NAME SETDIR [restore options]
  local d
  d=$(fresh "$1")
  restore --job streets --prev "$d/prev" --sources "$d/sources" --data "$d/data" "${@:3}"
  [[ $status -eq 0 ]] || fail "restore for $1: $err"
  cp "$2"/* "$d/data/"
  RUN=$d
}

begin "publish: the order (carried HEADs, blob PUTs, sidecar, dated copy, re-read, manifest, heartbeat last)"
reset_bucket
install_set "$work/setA"
prepare_run p1 "$work/setB"
: >"$FAKE_AWS_LOG"
publish --data "$RUN/data" --prev "$RUN/prev" --no-flows-upload --result-file "$RUN/result"; expect_status 0
[[ $(cat "$RUN/result") == published=1 ]] || fail "result: $(cat "$RUN/result")"
[[ $(current_set) == "$SET_B" ]] || fail "current set $(current_set)"
cmp -s "$bucket/data/heartbeat.json" "$work/setB/heartbeat.json" || fail "heartbeat"
sidecar_b=$(sha "$work/setB/trip-counts.json")
cmp -s "$bucket/data/trip-counts/$sidecar_b.json" "$work/setB/trip-counts.json" || fail "the sidecar is not stored by its sha"
cmp -s "$bucket/data/manifests/20261007T071500Z-$SET_B.json" "$work/setB/manifest.json" || fail "dated copy"
for name in tt-subway tt-bus config links; do
  cmp -s "$bucket/data/blobs/$(sha "$work/setB/$name.bin.xz").xz" "$work/setB/$name.bin.xz" || fail "$name blob"
done
order=$(call_order)
last_head=$(echo "$order" | grep -n '^head-object data/blobs/' | head -n 3 | tail -n 1 | cut -d: -f1)
first_put=$(line_of '^put-object ')
[[ $last_head -lt $first_put ]] || fail "a PUT before the carried HEADs: $order"
for name in streets stations flows; do
  expect_call "head-object --bucket test-bucket --key data/blobs/$(jq -r ".artifacts[\"$name\"].sha" "$work/setB/manifest.json").xz"
  expect_no_call "put-object --bucket test-bucket --key data/blobs/$(jq -r ".artifacts[\"$name\"].sha" "$work/setB/manifest.json").xz"
done
p_sidecar=$(line_of "^put-object data/trip-counts/")
p_dated=$(line_of "^put-object data/manifests/")
g_guard=$(call_order | grep -n '^get-object data/manifest.json' | tail -n 1 | cut -d: -f1)
p_manifest=$(line_of "^put-object data/manifest.json")
p_heartbeat=$(line_of "^put-object data/heartbeat.json")
last_blob=$(call_order | grep -n '^put-object data/blobs/' | tail -n 1 | cut -d: -f1)
[[ $last_blob -lt $p_sidecar && $p_sidecar -lt $p_dated && $p_dated -lt $g_guard && $g_guard -lt $p_manifest && $p_manifest -lt $p_heartbeat ]] ||
  fail "order: $order"
[[ $(call_order | tail -n 2 | head -n 1) == "put-object data/heartbeat.json" ]] || fail "heartbeat not last: $order"
[[ $(grep -c 'put-object' "$FAKE_AWS_LOG") == 11 ]] || fail "expected 7 blobs, sidecar, dated, manifest, heartbeat: $order"

begin "publish: built blobs are always PUT, even when R2 already has them"
reset_bucket
install_set "$work/setA"
cp "$work/setB/tt-bus.bin.xz" "$bucket/data/blobs/$(sha "$work/setB/tt-bus.bin.xz").xz"
age 202609010000 "$bucket/data/blobs/$(sha "$work/setB/tt-bus.bin.xz").xz"
prepare_run p2 "$work/setB"
publish --data "$RUN/data" --prev "$RUN/prev"; expect_status 0
expect_call "put-object --bucket test-bucket --key data/blobs/$(sha "$work/setB/tt-bus.bin.xz").xz"
[[ -n $(find "$bucket/data/blobs/$(sha "$work/setB/tt-bus.bin.xz").xz" -newermt '2026-09-02') ]] || fail "LastModified not refreshed"

begin "publish: a carried blob missing, or short, in R2 stops before anything is written"
reset_bucket
install_set "$work/setA"
prepare_run p3 "$work/setB"
flows_sha=$(jq -r '.artifacts.flows.sha' "$work/setB/manifest.json")
for what in missing short 403; do
  case $what in
    missing) mv "$bucket/data/blobs/$flows_sha.xz" "$work/files/flows.keep"; unset FAKE_AWS_FAIL ;;
    short) export FAKE_AWS_FAIL="head-object:data/blobs/$flows_sha.xz:short" ;;
    403) export FAKE_AWS_FAIL="head-object:data/blobs/$flows_sha.xz:403" ;;
  esac
  : >"$FAKE_AWS_LOG"
  publish --data "$RUN/data" --prev "$RUN/prev"; expect_status 1
  expect_err "flows"
  expect_no_call "put-object"
  [[ $(current_set) == "$SET_A" ]] || fail "$what: the current set changed"
  [[ $what != missing ]] || mv "$work/files/flows.keep" "$bucket/data/blobs/$flows_sha.xz"
done
unset FAKE_AWS_FAIL

begin "publish: a built blob that is not the manifest's, or a foreign sidecar or heartbeat, stops before any PUT"
cp "$RUN/data/tt-bus.bin.xz" "$work/files/ttbus.keep"
printf 'x' >>"$RUN/data/tt-bus.bin.xz"
: >"$FAKE_AWS_LOG"
publish --data "$RUN/data" --prev "$RUN/prev"; expect_status 1
expect_err "tt-bus.bin.xz"
expect_no_call "put-object"
cp "$work/files/ttbus.keep" "$RUN/data/tt-bus.bin.xz"
cp "$work/setA/heartbeat.json" "$RUN/data/heartbeat.json"
publish --data "$RUN/data" --prev "$RUN/prev"; expect_status 1
expect_err "heartbeat.json does not name set"
cp "$work/setB/heartbeat.json" "$RUN/data/heartbeat.json"
cp "$work/setA/trip-counts.json" "$RUN/data/trip-counts.json"
publish --data "$RUN/data" --prev "$RUN/prev"; expect_status 1
expect_err "not the sidecar"
cp "$work/setB/trip-counts.json" "$RUN/data/trip-counts.json"
expect_no_call "put-object"

begin "publish: a set built on another set than the restored one is refused"
make_set "$work/setC" 2026-10-07T08:00:00Z "$work/setB/manifest.json" c "tt-subway config links" "streets stations flows tt-bus tt-lirr tt-ferry tt-path"
d=$(fresh p5)
restore --job streets --prev "$d/prev" --sources "$d/sources" --data "$d/data"
cp "$work/setC"/* "$d/data/"
: >"$FAKE_AWS_LOG"
publish --data "$d/data" --prev "$d/prev"; expect_status 1
expect_err "built on set $SET_B, but R2's set was $SET_A"
expect_no_call "put-object"

begin "publish: the re-read guard stops when another caller published in between"
reset_bucket
install_set "$work/setA"
prepare_run p6 "$work/setB"
# Another caller makes set C current while this run uploads its dated copy.
make_set "$work/setOther" 2026-10-07T07:30:00Z "$work/setA/manifest.json" other "tt-subway config links" \
  "streets stations flows tt-bus tt-lirr tt-ferry tt-path"
other=$SET_ID
printf 'cp %q %q\n' "$work/setOther/manifest.json" "$bucket/data/manifest.json" >"$work/race.sh"
: >"$FAKE_AWS_LOG"
FAKE_AWS_AFTER="put-object:data/manifests/*:$work/race.sh" publish --data "$RUN/data" --prev "$RUN/prev"
expect_status 1
expect_err "is set $other now, not $SET_A"
[[ $(current_set) == "$other" ]] || fail "the other caller's set was overwritten"
expect_no_call "put-object --bucket test-bucket --key data/manifest.json"
expect_no_call "put-object --bucket test-bucket --key data/heartbeat.json"

begin "publish: on a first run the guard requires the manifest to be a 404 still"
reset_bucket
d=$(fresh p7)
restore --job streets --prev "$d/prev" --sources "$d/sources" --data "$d/data" --allow-first-run
cp "$work/setFirst"/* "$d/data/"
printf 'cp %q %q\n' "$work/setA/manifest.json" "$bucket/data/manifest.json" >"$work/race.sh"
mkdir -p "$bucket/data"
FAKE_AWS_AFTER="put-object:data/manifests/*:$work/race.sh" publish --data "$d/data" --prev "$d/prev"
expect_status 1
expect_err "appeared since the restore"
[[ $(current_set) == "$SET_A" ]] || fail "the first-run publish overwrote another set"
reset_bucket
publish --data "$d/data" --prev "$d/prev"; expect_status 0
[[ $(current_set) == "$(jq -r .setId "$work/setFirst/manifest.json")" ]] || fail "the first set was not published"

begin "publish: a hold that appears after the restore stops the publish (exit 0)"
reset_bucket
install_set "$work/setA"
prepare_run p8 "$work/setB"
put_hold '{"reason":"incident"}'
: >"$FAKE_AWS_LOG"
publish --data "$RUN/data" --prev "$RUN/prev" --result-file "$RUN/result"; expect_status 0
expect_err "on hold"
expect_no_call "put-object"
[[ $(cat "$RUN/result") == published=0 ]] || fail "result: $(cat "$RUN/result")"
rm "$bucket/data/hold.json"

begin "publish: --no-flows-upload refuses a set whose flows is built here, not carried"
make_set "$work/setFlows" 2026-10-07T09:00:00Z "$work/setA/manifest.json" fl "flows config links" \
  "streets stations tt-subway tt-bus tt-lirr tt-ferry tt-path"
prepare_run p9 "$work/setFlows"
: >"$FAKE_AWS_LOG"
publish --data "$RUN/data" --prev "$RUN/prev" --no-flows-upload; expect_status 1
expect_err "flows is built here"
expect_no_call "put-object"

begin "publish: a dry run reads (HEADs, hold, guard) and writes nothing"
prepare_run p10 "$work/setB"
: >"$FAKE_AWS_LOG"
publish --data "$RUN/data" --prev "$RUN/prev" --dry-run --result-file "$RUN/result"; expect_status 0
[[ $(cat "$RUN/result") == published=1 ]] || fail "a dry run's result: $(cat "$RUN/result")"
expect_err "[dry run] would put data/manifest.json"
expect_no_call "put-object"
expect_call "head-object --bucket test-bucket --key data/blobs/$flows_sha.xz"
[[ $(current_set) == "$SET_A" ]] || fail "a dry run published"

begin "publish: the hold read by restore stops publish-set too"
publish --data "$RUN/data" --prev "$work/held" --result-file "$work/files/held.result"; expect_status 0
expect_err "on hold"
[[ $(cat "$work/files/held.result") == published=0 ]] || fail "result: $(cat "$work/files/held.result")"

# --- sync-sources.sh -----------------------------------------------------------------------------

begin "sources upload: add-only, zip before record, never overwriting, never deleting"
reset_bucket
src=$(fresh u1)/sources
make_record "$src/gtfs/archive" gtfs_subway new 20261031 "subway new"
make_record "$src/gtfs/archive" gtfs_subway have 20261031 "subway have"
make_record "$bucket/sources" gtfs_subway have 20261031 "subway have, as R2 has it"
cp "$bucket/sources/gtfs_subway/have.zip" "$work/files/have.r2"
: >"$FAKE_AWS_LOG"
run "$scripts/sync-sources.sh" upload --sources "$src"; expect_status 0
cmp -s "$bucket/sources/gtfs_subway/new.zip" "$src/gtfs/archive/gtfs_subway/new.zip" || fail "new.zip"
cmp -s "$bucket/sources/gtfs_subway/new.json" "$src/gtfs/archive/gtfs_subway/new.json" || fail "new.json"
cmp -s "$bucket/sources/gtfs_subway/have.zip" "$work/files/have.r2" || fail "an existing key was overwritten"
[[ $(line_of "^put-object sources/gtfs_subway/new.zip") -lt $(line_of "^put-object sources/gtfs_subway/new.json") ]] || fail "record before zip"
[[ $(grep -c put-object "$FAKE_AWS_LOG") == 2 ]] || fail "puts: $(call_order)"
expect_no_call "delete-object"

begin "sources upload: a record whose zip does not match is skipped, the rest uploaded, then exit 1"
make_record "$src/gtfs/archive" gtfs_bus good 20261231 "bus good"
make_record "$src/gtfs/archive" gtfs_bus bad 20261231 "bus bad"
printf 'changed' >"$src/gtfs/archive/gtfs_bus/bad.zip"
run "$scripts/sync-sources.sh" upload --sources "$src"; expect_status 1
[[ -f $bucket/sources/gtfs_bus/good.zip && ! -e $bucket/sources/gtfs_bus/bad.zip ]] || fail "good not uploaded, or bad uploaded"
rm -rf "$bucket/sources/gtfs_bus"
: >"$FAKE_AWS_LOG"
run "$scripts/sync-sources.sh" upload --sources "$src" --dry-run; expect_status 1
expect_err "[dry run] would put sources/gtfs_bus/good.zip"
expect_no_call "put-object"

begin "sources prune: after a publish, the records the build dropped and those 30 days past their calendar"
reset_bucket
d=$(fresh u2)
for r in "gtfs_subway kept 20261031" "gtfs_subway dropped 20261031" "gtfs_bus ended 20260906" "gtfs_bus recent 20260907" \
  "gtfs_ferry nocal -"; do
  read -r feed key end <<<"$r"
  make_record "$bucket/sources" "$feed" "$key" "$end" "$feed $key"
done
restore --job timetables --prev "$d/prev" --sources "$d/sources" --data "$d/data" --allow-first-run; expect_status 0
# The build drops one restored version (no longer selectable on any date).
rm "$d/sources/gtfs/archive/gtfs_subway/dropped.zip" "$d/sources/gtfs/archive/gtfs_subway/dropped.json"
: >"$FAKE_AWS_LOG"
run "$scripts/sync-sources.sh" prune --sources "$d/sources" --restored "$d/prev/sources-restored.txt" --today "$DAY" --dry-run
expect_status 0
expect_no_call "delete-object"
expect_err "[dry run] would delete sources/gtfs_bus/ended.zip"
run "$scripts/sync-sources.sh" prune --sources "$d/sources" --restored "$d/prev/sources-restored.txt" --today "$DAY"
expect_status 0
remaining=$(cd "$bucket/sources" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | tr '\n' ' ')
[[ $remaining == "gtfs_bus/recent.json gtfs_bus/recent.zip gtfs_ferry/nocal.json gtfs_ferry/nocal.zip gtfs_subway/kept.json gtfs_subway/kept.zip " ]] ||
  fail "left: $remaining"
[[ $(line_of "^delete-object sources/gtfs_subway/dropped.json") -lt $(line_of "^delete-object sources/gtfs_subway/dropped.zip") ]] ||
  fail "zip deleted before its record"

begin "sources prune: refuses a plan over the cap, and an archive that vanished, deleting nothing"
make_record "$bucket/sources" gtfs_lirr a 20200101 "lirr a"
make_record "$bucket/sources" gtfs_lirr b 20200101 "lirr b"
d=$(fresh u3)
restore --job timetables --prev "$d/prev" --sources "$d/sources" --data "$d/data" --allow-first-run; expect_status 0
: >"$FAKE_AWS_LOG"
run "$scripts/sync-sources.sh" prune --sources "$d/sources" --restored "$d/prev/sources-restored.txt" --today "$DAY" --max-deletions 3
expect_status 1
expect_err "more than --max-deletions 3"
expect_no_call "delete-object"
rm -rf "$d/sources/gtfs"
run "$scripts/sync-sources.sh" prune --sources "$d/sources" --restored "$d/prev/sources-restored.txt" --today "$DAY"
expect_status 1
expect_err "every record would look pruned"
expect_no_call "delete-object"

begin "sources aux: the last good copy is replaced only when it changed, and only the files named"
reset_bucket
d=$(fresh u4)
mkdir -p "$d/sources/nyc" "$bucket/sources/aux"
printf 'entrances v2\n' >"$d/sources/nyc/subway-entrances.csv"
printf 'boundaries\n' >"$d/sources/nyc/borough-boundaries-water-included.geojson"
printf 'entrances v1\n' >"$bucket/sources/aux/subway-entrances.csv"
run "$scripts/sync-sources.sh" aux --sources "$d/sources" --files entrances; expect_status 0
cmp -s "$bucket/sources/aux/subway-entrances.csv" "$d/sources/nyc/subway-entrances.csv" || fail "entrances not replaced"
[[ ! -e $bucket/sources/aux/borough-boundaries.geojson ]] || fail "boundaries uploaded without being named"
: >"$FAKE_AWS_LOG"
run "$scripts/sync-sources.sh" aux --sources "$d/sources" --files entrances,boundaries; expect_status 0
expect_no_call "put-object --bucket test-bucket --key sources/aux/subway-entrances.csv"
cmp -s "$bucket/sources/aux/borough-boundaries.geojson" "$d/sources/nyc/borough-boundaries-water-included.geojson" || fail "boundaries"

# --- gc-data.sh ----------------------------------------------------------------------------------

# A history of sets: S1..S10, one a day from 2026-09-01, then a gap, then S11 (2026-10-06) and the
# current S12 (2026-10-07). Each builds its own tt-bus; everything else is carried from S1.
gc_fixture() {
  reset_bucket
  rm -rf "$work/gc"
  make_set "$work/gc/s1" 2026-09-01T07:15:00Z - s1 "$CORE"
  install_set "$work/gc/s1"
  local i prev="$work/gc/s1/manifest.json" day
  for i in 2 3 4 5 6 7 8 9 10 11 12; do
    if [[ $i -le 10 ]]; then day=$(printf '2026-09-%02d' "$i"); else day=$(printf '2026-10-%02d' $((i - 5))); fi
    make_set "$work/gc/s$i" "${day}T07:15:00Z" "$prev" "s$i" "tt-bus" "streets stations tt-subway tt-lirr tt-ferry tt-path config links"
    install_set "$work/gc/s$i"
    prev="$work/gc/s$i/manifest.json"
  done
  # Every object is old, except what the tests make young.
  find "$bucket" -type f -exec env TZ=UTC touch -t 202609010000 {} +
  blob_of() { printf '%s/data/blobs/%s.xz' "$bucket" "$(sha "$work/gc/s$1/tt-bus.bin.xz")"; }
  sidecar_of() { printf '%s/data/trip-counts/%s.json' "$bucket" "$(sha "$work/gc/s$1/trip-counts.json")"; }
}

begin "gc: roots are the current set and the retained dated manifests; unreferenced blobs go after 48 h"
gc_fixture
# An orphan from a torn publish: young (kept) and old (deleted).
printf 'orphan young' >"$bucket/data/blobs/$(printf 'a%.0s' $(seq 64)).xz"
age 202610070000 "$bucket/data/blobs/$(printf 'a%.0s' $(seq 64)).xz"
printf 'orphan old' >"$bucket/data/blobs/$(printf 'b%.0s' $(seq 64)).xz"
put_hold '{"reason":"x"}'
run "$scripts/gc-data.sh" --now "$NOW"; expect_status 0
# Retained: the newest 7 (S12..S6) and the last 30 days (from 2026-09-07: S7..S12, inside the 7).
for i in 6 7 8 9 10 11 12; do
  [[ -f $(blob_of "$i") && -f $(sidecar_of "$i") ]] || fail "S$i's blob or sidecar was deleted"
done
for i in 2 3 4 5; do
  [[ ! -e $(blob_of "$i") && ! -e $(sidecar_of "$i") ]] || fail "S$i's blob or sidecar was kept"
done
[[ $(find "$bucket/data/manifests" -type f | wc -l | tr -d ' ') == 7 ]] || fail "dated manifests left: $(ls "$bucket/data/manifests")"
[[ -f $(blob_of 1) ]] && fail "S1's own tt-bus blob was kept"
[[ -f "$bucket/data/blobs/$(sha "$work/gc/s1/streets.bin.xz").xz" ]] || fail "a carried blob of the current set was deleted"
[[ -f "$bucket/data/blobs/$(printf 'a%.0s' $(seq 64)).xz" ]] || fail "a young orphan was deleted"
[[ ! -e "$bucket/data/blobs/$(printf 'b%.0s' $(seq 64)).xz" ]] || fail "an old orphan was kept"
[[ -f $bucket/data/manifest.json && -f $bucket/data/heartbeat.json && -f $bucket/data/hold.json ]] || fail "a fixed key was deleted"

begin "gc: the 30 days keep more than 7; a dated copy of the current set is always kept"
gc_fixture
run "$scripts/gc-data.sh" --now 2026-10-02T07:00:00Z --dry-run; expect_status 0
expect_no_call "delete-object"
# From 2026-09-02T07:00 on: S2..S12 are inside 30 days; only S1's dated copy (2026-09-01) goes.
expect_err "would delete data/manifests/20260901T071500Z-"
[[ $(grep -c 'would delete data/manifests/' "$work/err") == 1 ]] || fail "plan: $err"
cp "$work/gc/s1/manifest.json" "$bucket/data/manifest.json"
run "$scripts/gc-data.sh" --now "$NOW" --dry-run; expect_status 0
[[ $err != *"would delete data/manifests/20260901T071500Z-"* ]] || fail "the current set's dated copy would go: $err"
[[ $err != *"would delete data/blobs/$(sha "$work/gc/s1/tt-bus.bin.xz").xz"* ]] || fail "the current set's blob would go"

begin "gc: fails closed on a list, GET or parse error, or an unreadable key, deleting nothing"
gc_fixture
for rule in "list-objects-v2:data/:500" "get-object:data/manifest.json:403" "get-object:data/manifests/20260908*:500"; do
  : >"$FAKE_AWS_LOG"
  FAKE_AWS_FAIL=$rule run "$scripts/gc-data.sh" --now "$NOW"; expect_status 1
  expect_no_call "delete-object"
done
dated=$(find "$bucket/data/manifests" -type f | LC_ALL=C sort | sed -n 10p)
dated=${dated##*/}
cp "$bucket/data/manifests/$dated" "$work/files/dated.keep"
printf '{"schema":1}' >"$bucket/data/manifests/$dated"
: >"$FAKE_AWS_LOG"
run "$scripts/gc-data.sh" --now "$NOW"; expect_status 1
expect_err "is not a manifest"
expect_no_call "delete-object"
cp "$work/files/dated.keep" "$bucket/data/manifests/$dated"
printf 'x' >"$bucket/data/manifests/latest.json"
: >"$FAKE_AWS_LOG"
run "$scripts/gc-data.sh" --now "$NOW"; expect_status 1
expect_err "unreadable key data/manifests/latest.json"
expect_no_call "delete-object"
rm "$bucket/data/manifests/latest.json"

begin "gc: a plan over --max-deletions deletes nothing"
: >"$FAKE_AWS_LOG"
run "$scripts/gc-data.sh" --now "$NOW" --max-deletions 5; expect_status 1
expect_err "more than --max-deletions 5"
expect_no_call "delete-object"

begin "gc: no current manifest means no roots: nothing deleted, and a failure unless data/ is empty"
rm "$bucket/data/manifest.json"
: >"$FAKE_AWS_LOG"
run "$scripts/gc-data.sh" --now "$NOW"; expect_status 1
expect_err "no roots"
expect_no_call "delete-object"

begin "gc: fails when data/ is over the size limit"
gc_fixture
run "$scripts/gc-data.sh" --now "$NOW" --max-bytes 100; expect_status 1
expect_err "over the 100 limit"

# --- rollback.sh ---------------------------------------------------------------------------------

begin "rollback: the old manifest re-stamped, a new dated copy, the hold written first, then data/manifest.json"
reset_bucket
install_set "$work/setA"
install_set "$work/setB"
: >"$FAKE_AWS_LOG"
run "$scripts/rollback.sh" "$SET_A" --reason "bad stops" --until 2026-10-08T00:00:00Z --now "$NOW"; expect_status 0
[[ $(current_set) == "$SET_A" ]] || fail "current set $(current_set)"
[[ $(jq -r .generatedAt "$bucket/data/manifest.json") == "$NOW" ]] || fail "generatedAt not re-stamped"
[[ $(jq -c 'del(.generatedAt)' "$bucket/data/manifest.json") == "$(jq -c 'del(.generatedAt)' "$work/setA/manifest.json")" ]] ||
  fail "the manifest changed beyond generatedAt"
cmp -s "$bucket/data/manifests/20261007T120000Z-$SET_A.json" "$bucket/data/manifest.json" || fail "no dated copy"
[[ $(cat "$bucket/data/hold.json") == '{"reason":"bad stops","until":"2026-10-08T00:00:00Z"}' ]] || fail "hold: $(cat "$bucket/data/hold.json")"
[[ $(line_of "^put-object data/hold.json") -lt $(line_of "^put-object data/manifest.json") ]] || fail "the hold came after the manifest"
for name in $CORE flows; do expect_call "head-object --bucket test-bucket --key data/blobs/$(jq -r ".artifacts[\"$name\"].sha" "$work/setA/manifest.json").xz"; done
expect_call "head-object --bucket test-bucket --key data/trip-counts/$(sha "$work/setA/trip-counts.json").json"
d=$(fresh rb1)
restore --job timetables --prev "$d/prev" --sources "$d/sources" --data "$d/data"; expect_status 0
[[ $(sed -n 's/^HOLD=//p' "$d/prev/state.env") == 1 ]] || fail "the next run is not held"
d=$(fresh rb1b)
restore --job timetables --prev "$d/prev" --sources "$d/sources" --data "$d/data" --now 2026-10-08T00:00:01Z; expect_status 0
[[ $(sed -n 's/^PREV_SET=//p' "$d/prev/state.env") == "$SET_A" ]] || fail "after the hold, the next run does not build on the rolled-back set"

begin "rollback: a blob or sidecar gone, a time not later than the current set's, or no dated copy: nothing written"
reset_bucket
install_set "$work/setA"
install_set "$work/setB"
cp -R "$bucket" "$work/files/bucket.keep"
rm "$bucket/data/blobs/$(sha "$work/setA/tt-bus.bin.xz").xz"
: >"$FAKE_AWS_LOG"
run "$scripts/rollback.sh" "$SET_A" --reason x --now "$NOW"; expect_status 1
expect_err "no longer in R2"
expect_no_call "put-object"
rm -rf "$bucket" && cp -R "$work/files/bucket.keep" "$bucket"
rm "$bucket/data/trip-counts/$(sha "$work/setA/trip-counts.json").json"
run "$scripts/rollback.sh" "$SET_A" --reason x --now "$NOW"; expect_status 1
expect_err "sidecar is no longer in R2"
rm -rf "$bucket" && cp -R "$work/files/bucket.keep" "$bucket"
: >"$FAKE_AWS_LOG"
run "$scripts/rollback.sh" "$SET_A" --reason x --now 2026-10-07T07:15:00Z; expect_status 1
expect_err "not later than the current set's generatedAt"
run "$scripts/rollback.sh" 0123456789abcdef --reason x --now "$NOW"; expect_status 1
expect_err "no dated manifest of set 0123456789abcdef"
expect_no_call "put-object"

begin "rollback: the guard stops it when another caller publishes in between (the hold stays)"
printf 'cp %q %q\n' "$work/setC/manifest.json" "$bucket/data/manifest.json" >"$work/race.sh"
FAKE_AWS_AFTER="put-object:data/hold.json:$work/race.sh" run "$scripts/rollback.sh" "$SET_A" --reason x --now "$NOW"
expect_status 1
expect_err "the hold stays"
[[ $(current_set) == "$(jq -r .setId "$work/setC/manifest.json")" ]] || fail "the other caller's set was overwritten"
[[ -f $bucket/data/hold.json ]] || fail "no hold"

begin "rollback: a dry run reads and writes nothing"
rm -rf "$bucket" && cp -R "$work/files/bucket.keep" "$bucket"
: >"$FAKE_AWS_LOG"
run "$scripts/rollback.sh" "$SET_A" --reason x --now "$NOW" --dry-run; expect_status 0
expect_no_call "put-object"
expect_err "[dry run] would put data/hold.json"
[[ $(current_set) == "$SET_B" && ! -e $bucket/data/hold.json ]] || fail "a dry run changed the bucket"

# --- publish-local.sh ----------------------------------------------------------------------------

begin "publish-local --first: keys from the env file, flows from the Mac, the first set published, sources uploaded"
reset_bucket
make_set "$work/macData" 2026-10-07T07:15:00Z - mac "$CORE flows"
mac_set=$SET_ID
mkdir -p "$work/macReports" "$work/macSources/gtfs/archive"
printf '{"report":"flows"}' >"$work/macReports/flows.json"
make_record "$work/macSources/gtfs/archive" gtfs_subway mac 20261031 "subway from the mac"
cat >"$work/files/bootstrap.env" <<ENV
# the data bucket
R2_ACCOUNT_ID=$R2_ACCOUNT_ID
R2_DATA_BUCKET=test-bucket
R2_DATA_ACCESS_KEY_ID=$key_id
R2_DATA_SECRET_ACCESS_KEY="$secret_key"
OTHER=\$(touch $work/files/sourced)
ENV
: >"$FAKE_BRD_LOG"
FAKE_BRD_SET="$work/macData" run env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u R2_BUCKET \
  "$scripts/publish-local.sh" --work "$work/local1" --env "$work/files/bootstrap.env" --first \
  --flows-from "$work/macData" --flows-report "$work/macReports/flows.json" --sources "$work/macSources"
expect_status 0
[[ ! -e $work/files/sourced ]] || fail "the env file was sourced"
[[ $(current_set) == "$mac_set" ]] || fail "not published"
[[ $(jq -r '.previousSetId // "none"' "$bucket/data/manifest.json") == none ]] || fail "a first set with a previousSetId"
cmp -s "$work/local1/reports/flows.json" "$work/macReports/flows.json" || fail "the flows report was not placed"
[[ $(cat "$FAKE_BRD_LOG") == "all --out $work/local1/data --sources $work/local1/sources --skip flows --require-flows --job all --today "* &&
  $(cat "$FAKE_BRD_LOG") != *--previous* ]] || fail "arguments: $(cat "$FAKE_BRD_LOG")"
[[ $(cat "$FAKE_BRD_LOG") == *" --strict-sources "* && $(cat "$FAKE_BRD_LOG") == *" --cached-extracts"* ]] ||
  fail "--sources given: no --strict-sources or --cached-extracts: $(cat "$FAKE_BRD_LOG")"
[[ -f $bucket/sources/gtfs_subway/mac.zip ]] || fail "the Mac's sources were not uploaded"
expect_call "put-object --bucket test-bucket --key data/blobs/$(jq -r .artifacts.flows.sha "$work/macData/manifest.json").xz"

begin "publish-local: --first against a bucket with a set, and a streets sanity failure, publish nothing"
: >"$FAKE_AWS_LOG"
FAKE_BRD_SET="$work/macData" run "$scripts/publish-local.sh" --work "$work/local2" --env "$work/files/bootstrap.env" --first \
  --flows-from "$work/macData" --flows-report "$work/macReports/flows.json"
expect_status 1
expect_err "already has set $mac_set"
expect_no_call "put-object"
make_set "$work/macNext" 2026-10-07T13:00:00Z "$work/macData/manifest.json" next "$CORE" "flows"
: >"$FAKE_AWS_LOG"
FAKE_BRD_SANITY=false FAKE_BRD_SET="$work/macNext" run "$scripts/publish-local.sh" --work "$work/local3" \
  --env "$work/files/bootstrap.env"
expect_status 1
expect_err "sanity routes"
expect_no_call "put-object --bucket test-bucket --key data/"
[[ $(current_set) == "$mac_set" ]] || fail "published anyway"

begin "publish-local: a subway without entrances stops all (--strict-sources); nothing published"
: >"$FAKE_AWS_LOG"
: >"$FAKE_BRD_LOG"
FAKE_BRD_WARNING="subway entrances unavailable (offline); built without entrances" FAKE_BRD_SET="$work/macNext" \
  run "$scripts/publish-local.sh" --work "$work/local3b" --env "$work/files/bootstrap.env"
expect_status 1
expect_err "stopped with status 1"
[[ $(cat "$FAKE_BRD_LOG") == *" --strict-sources "* ]] || fail "arguments: $(cat "$FAKE_BRD_LOG")"
expect_no_call "put-object --bucket test-bucket --key data/"
[[ $(current_set) == "$mac_set" ]] || fail "published anyway"

begin "publish-local: a later run builds on the set in R2, carrying its flows"
: >"$FAKE_BRD_LOG"
FAKE_BRD_SET="$work/macNext" run "$scripts/publish-local.sh" --work "$work/local4" --env "$work/files/bootstrap.env"
expect_status 0
[[ $(cat "$FAKE_BRD_LOG") == *"--previous $work/local4/prev/manifest.json" ]] || fail "arguments: $(cat "$FAKE_BRD_LOG")"
[[ $(cat "$FAKE_BRD_LOG") == *" --strict-sources "* && $(cat "$FAKE_BRD_LOG") != *--cached-extracts* ]] ||
  fail "no --sources: --strict-sources without --cached-extracts expected: $(cat "$FAKE_BRD_LOG")"
[[ $(current_set) == "$(jq -r .setId "$work/macNext/manifest.json")" ]] || fail "not published"

begin "publish-local: a hold that begins after the restore stops the publish, the prune and the aux files"
# A version 30 days past its calendar, which the prune would delete, and entrances the aux step
# would put.
make_record "$bucket/sources" gtfs_bus ended 20260801 "bus ended long ago"
mkdir -p "$work/macSources2/nyc"
printf 'entrances\n' >"$work/macSources2/nyc/subway-entrances.csv"
make_set "$work/macThird" 2026-10-07T20:00:00Z "$work/macNext/manifest.json" third "$CORE" "flows"
printf 'printf %%s %q >%q\n' '{"reason":"incident"}' "$bucket/data/hold.json" >"$work/hold.sh"
before=$(current_set)
: >"$FAKE_AWS_LOG"
FAKE_AWS_AFTER="list-objects-v2:sources/:$work/hold.sh" FAKE_BRD_SET="$work/macThird" run "$scripts/publish-local.sh" \
  --work "$work/local5" --env "$work/files/bootstrap.env" --sources "$work/macSources2"
expect_status 0
expect_err "went on hold during the run"
[[ $(current_set) == "$before" ]] || fail "published through the hold"
expect_no_call "delete-object"
expect_no_call "put-object --bucket test-bucket --key data/"
expect_no_call "put-object --bucket test-bucket --key sources/aux/"
[[ -f $bucket/sources/gtfs_bus/ended.zip ]] || fail "pruned during the hold"
rm "$bucket/data/hold.json"

# --- set-summary.sh ------------------------------------------------------------------------------

begin "set-summary: setIds, sizes built or carried, coverage, gate checks, where flows came from"
run "$scripts/set-summary.sh" "$work/setB/manifest.json"; expect_status 0
[[ $out == *"Set \`$SET_B\`"* && $out == *"previous set: \`$SET_A\`"* ]] || fail "setIds: $out"
[[ $out == *"flows: carried from set \`$SET_A\`"* ]] || fail "flows: $out"
[[ $out == *"| streets | $(size "$work/setA/streets.bin.xz") | carried |"* && $out == *"| tt-bus | $(size "$work/setB/tt-bus.bin.xz") | built |"* ]] ||
  fail "sizes: $out"
[[ $out == *"| subway | 25 | 2026-10-31 | ok |"* && $out == *"| tripCounts | skipped | 1 |"* ]] || fail "coverage or gate: $out"
[[ $out != *private/* && $out != *history/* ]] || fail "a key outside data/ and sources/: $out"


begin "set-summary --gate: acceptedTripCountChange from gate.json, with each system's accepted dates; only known names"
jq -n '{status: "pass", acceptedTripCountChange: ["path", "subway", "`rm -rf /`", 7],
        checks: [{name: "tripCounts", status: "pass", metrics: {"subway.acceptedDates": 3, "path.acceptedDates": 0}}]}' \
  >"$work/files/gate.json"
run "$scripts/set-summary.sh" --gate "$work/files/gate.json"; expect_status 0
[[ $out == "- trip-count change accepted by the gate (gate.json): path (0 dates beyond the limit), subway (3 dates beyond the limit)" ]] ||
  fail "accepted: $out"
jq -n '{status: "fail", checks: [{name: "tripCounts", status: "fail", metrics: {}}]}' >"$work/files/gate.json"
run "$scripts/set-summary.sh" --gate "$work/files/gate.json"; expect_status 0
[[ -z $out ]] || fail "no acceptedTripCountChange, yet: $out"
printf 'not json' >"$work/files/gate.json"
run "$scripts/set-summary.sh" --gate "$work/files/gate.json"; expect_status 1
run "$scripts/set-summary.sh" --gate; expect_status 64

begin "set-summary --sources: the feeds built from an archived copy (status cached), names and dates only"
jq -n '{systems: {
  "tt-bus": {stats: {sources: [{name: "gtfs_b", status: "cached", archivedAt: "2026-10-03T12:00:00Z", archiveKey: "k1"},
                               {name: "gtfs_m"}, {name: "gtfs_q", status: "downloaded"}]}},
  "tt-subway": {stats: {sources: [{name: "gtfs_supplemented", status: "cached", archivedAt: "2026-10-05T01:02:03Z"}]}},
  "tt-path": {stats: {sources: [{name: "`rm -rf /`", status: "cached", archivedAt: "yesterday"}]}},
  "tt-ferry": "not an entry", "tt-lirr": {stats: {sources: "none"}},
  "private/flows": {stats: {sources: [{name: "x", status: "cached"}]}}}}' >"$work/files/timetables.json"
run "$scripts/set-summary.sh" --sources "$work/files/timetables.json"; expect_status 0
[[ $out == "- **built from an archived copy** (its download failed): tt-bus gtfs_b, first archived 2026-10-03
- **built from an archived copy** (its download failed): tt-path (unnamed feed)
- **built from an archived copy** (its download failed): tt-subway gtfs_supplemented, first archived 2026-10-05" ]] ||
  fail "cached feeds: $out"
jq -n '{systems: {"tt-bus": {stats: {sources: [{name: "gtfs_b"}]}}}}' >"$work/files/timetables.json"
run "$scripts/set-summary.sh" --sources "$work/files/timetables.json"; expect_status 0
[[ -z $out ]] || fail "nothing cached, yet: $out"
printf '[]' >"$work/files/timetables.json"
run "$scripts/set-summary.sh" --sources "$work/files/timetables.json"; expect_status 1
run "$scripts/set-summary.sh" --sources; expect_status 64

finish

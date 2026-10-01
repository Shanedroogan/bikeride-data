#!/usr/bin/env bash
# Tests of scripts/r2.sh against scripts/test/fake-aws. Nothing here reaches the network or a real
# bucket (scripts/test/harness.sh).
#
#   scripts/test/r2-test.sh
#
# Every r2.sh call's stdout and stderr are checked for the key pair, the account id, the R2
# endpoint and signed-URL text, which the fake prints on every failure.
# shellcheck source-path=SCRIPTDIR source=harness.sh
. "$(dirname "$0")/harness.sh"
r2="$repo/scripts/r2.sh"
r2() { run "$r2" "$@"; }

printf 'hello\n' >"$work/files/hello.json"
head -c 70000 /dev/zero | tr '\0' 'x' >"$work/files/blob.xz"

# --- The guard ---------------------------------------------------------------------------------

begin "history/ and fixtures/ are refused for every operation, before any call"
for key in history/gbfs/raw/2026-09-30/x.json history/backtest/daily/x.json fixtures/blobs/abc fixtures/x/manifest.json; do
  r2 get "$key" "$work/files/out"; expect_status 77; expect_err "never touched"
  r2 head "$key"; expect_status 77
  r2 put "$work/files/hello.json" "$key"; expect_status 77
  r2 delete "$key"; expect_status 77
done
for prefix in history/ fixtures/ history/gbfs/; do r2 list "$prefix"; expect_status 77; done
R2_DRY_RUN=1 r2 delete history/gbfs/raw/x.json; expect_status 77
R2_DRY_RUN=1 r2 put "$work/files/hello.json" fixtures/x; expect_status 77
R2_ALLOW_PRIVATE_FLOWS=1 r2 delete history/x; expect_status 77
expect_no_calls

begin "keys outside the allowlist, or not plain, are refused"
# shellcheck disable=SC2016 # a literal $( in a key
for key in "" data data/ sources Data/manifest.json datax/manifest.json /data/manifest.json data//manifest.json \
  data/./manifest.json data/../history/x.json "data/a b.json" 'data/$(id).json' "data/x*" private/flows/reports/x.json \
  private/x.json bike-ride/data/x.json; do
  r2 head "$key"; expect_status 77
  r2 delete "$key"; expect_status 77
done
for prefix in "" / data sources private/flows/ private/ "*" ./data/; do r2 list "$prefix"; expect_status 77; done
r2 head "data/$(printf 'a%.0s' $(seq 1 600))"; expect_status 77
expect_no_calls

begin "private/flows/ only with R2_ALLOW_PRIVATE_FLOWS=1"
R2_ALLOW_PRIVATE_FLOWS=1 r2 put "$work/files/hello.json" private/flows/reports/abc.json
expect_status 0
[[ -f $bucket/private/flows/reports/abc.json ]] || fail "not stored"
R2_ALLOW_PRIVATE_FLOWS=1 r2 list private/flows/; expect_status 0
[[ $out == private/flows/reports/abc.json$'\t'6$'\t'* ]] || fail "listing: $out"
rm -rf "$bucket/private"

# --- Round trip ----------------------------------------------------------------------------------

begin "put stores with put-object --content-md5, then HEADs; get returns the bytes"
r2 put "$work/files/blob.xz" data/blobs/0123abcd.xz; expect_status 0
cmp -s "$work/files/blob.xz" "$bucket/data/blobs/0123abcd.xz" || fail "stored bytes differ"
expect_call "s3api put-object --bucket test-bucket --key data/blobs/0123abcd.xz --body .* --content-md5 .* --content-type application/x-xz"
expect_call "s3api head-object --bucket test-bucket --key data/blobs/0123abcd.xz"
grep -q " s3 \| cp \|multipart" "$FAKE_AWS_LOG" && fail "an s3 cp or multipart call: $(cat "$FAKE_AWS_LOG")"
[[ $(grep -c ' s3api ' "$FAKE_AWS_LOG") == 2 ]] || fail "expected put then head only: $(cat "$FAKE_AWS_LOG")"
r2 get data/blobs/0123abcd.xz "$work/files/fetched/blob.xz"; expect_status 0
cmp -s "$work/files/blob.xz" "$work/files/fetched/blob.xz" || fail "fetched bytes differ"
r2 head data/blobs/0123abcd.xz; expect_status 0
[[ $out == 70000$'\t'*$'\t'????-??-??T??:??:??+00:00 && $out != *'"'* ]] || fail "head line: $out"

begin "put picks the content type from the key, or takes one"
r2 put "$work/files/hello.json" data/manifest.json; expect_status 0
expect_call "--content-type application/json"
r2 put "$work/files/hello.json" sources/aux/borough-boundaries.geojson; expect_status 0
expect_call "--content-type application/geo+json"
r2 put "$work/files/hello.json" data/heartbeat.json text/plain; expect_status 0
expect_call "--content-type text/plain"

begin "Content-MD5 is the base64 of the binary MD5 (the fake refuses a wrong one, as R2 does)"
r2 put "$work/files/hello.json" data/hold.json; expect_status 0
md5_from_r2=$(grep -o -- '--content-md5 [^ ]*' "$FAKE_AWS_LOG" | head -1 | cut -d' ' -f2)
if command -v openssl >/dev/null 2>&1; then
  [[ $md5_from_r2 == "$(openssl dgst -md5 -binary "$work/files/hello.json" | base64)" ]] || fail "Content-MD5 $md5_from_r2"
fi
[[ $md5_from_r2 == sZRqySSS0jR8YjW00mERhA== ]] || fail "Content-MD5 of 'hello\\n' is $md5_from_r2"
rm -f "$bucket/data/hold.json"

begin "a put whose file cannot be hashed never reaches put-object (no empty Content-MD5)"
# Both hashers r2.sh looks for print something that is not a digest.
for hasher in md5sum md5; do printf '#!/bin/sh\necho nope\n' >"$work/bin/$hasher"; chmod +x "$work/bin/$hasher"; done
r2 put "$work/files/hello.json" data/manifest.json; expect_status 12
expect_err "cannot hash"
! grep -q put-object "$FAKE_AWS_LOG" || fail "put-object ran: $(cat "$FAKE_AWS_LOG")"
rm -f "$work/bin/md5sum" "$work/bin/md5"

begin "list prints key, size and LastModified under the prefix only"
r2 list data/blobs/; expect_status 0
[[ $out == data/blobs/0123abcd.xz$'\t'70000$'\t'????-??-??T??:??:??+00:00 ]] || fail "listing: $out"
r2 list data/; expect_status 0
[[ $(printf '%s\n' "$out" | wc -l | tr -d ' ') == 3 ]] || fail "data/ listing: $out"
[[ $out != *sources/* ]] || fail "listing left the prefix: $out"
r2 list data/manifests/; expect_status 0
[[ -z $out ]] || fail "an empty listing printed: $out"
expect_call "s3api list-objects-v2 --bucket test-bucket --prefix data/manifests/"

begin "delete removes"
r2 delete data/heartbeat.json; expect_status 0
[[ ! -e $bucket/data/heartbeat.json ]] || fail "still there"
expect_call "s3api delete-object --bucket test-bucket --key data/heartbeat.json"

begin "a dry run plans put and delete and touches nothing"
R2_DRY_RUN=1 r2 put "$work/files/hello.json" data/hold.json; expect_status 0
expect_err "[dry run] would put data/hold.json (6 bytes"
R2_DRY_RUN=1 r2 delete data/blobs/0123abcd.xz; expect_status 0
expect_err "[dry run] would delete data/blobs/0123abcd.xz"
[[ ! -e $bucket/data/hold.json && -f $bucket/data/blobs/0123abcd.xz ]] || fail "the dry run changed the bucket"
expect_no_calls
R2_DRY_RUN=1 r2 head data/blobs/0123abcd.xz; expect_status 0

# --- 404 versus 403 versus the rest ------------------------------------------------------------

begin "not found is 10, on get (NoSuchKey) and head (404)"
printf 'old\n' >"$work/files/existing.json"
r2 get data/manifest-missing.json "$work/files/existing.json"; expect_status 10
expect_err "get data/manifest-missing.json: not found (exit 10)"
[[ $(cat "$work/files/existing.json") == old ]] || fail "a failed get changed the destination"
for partial in "$work/files"/*r2-partial*; do [[ ! -e $partial ]] || fail "a partial file was left: $partial"; done
r2 head data/missing.json; expect_status 10
expect_err "head data/missing.json: not found (exit 10)"

begin "access denied is 11, never 'not found'"
for op in get-object head-object list-objects-v2 put-object delete-object; do
  export FAKE_AWS_FAIL="$op:data/*:403"
  case $op in
    get-object) r2 get data/manifest.json "$work/files/m.json" ;;
    head-object) r2 head data/manifest.json ;;
    list-objects-v2) r2 list data/ ;;
    put-object) r2 put "$work/files/hello.json" data/manifest.json ;;
    delete-object) r2 delete data/manifest.json ;;
  esac
  expect_status 11
  expect_err "access denied (exit 11)"
  [[ $err != *"not found"* ]] || fail "$op: 403 reported as not found"
done
unset FAKE_AWS_FAIL
[[ ! -e $work/files/m.json ]] || fail "a denied get wrote its destination"

begin "a 5xx or the network is 12, never 'not found'"
for what in 500 network; do
  export FAKE_AWS_FAIL="get-object:data/manifest.json:$what head-object:data/*:$what"
  r2 get data/manifest.json "$work/files/m.json"; expect_status 12
  expect_err "get data/manifest.json: failed (aws exit 25"
  r2 head data/blobs/0123abcd.xz; expect_status 12
done
unset FAKE_AWS_FAIL

begin "a size mismatch after a PUT is 12"
export FAKE_AWS_FAIL="head-object:data/blobs/short.xz:short"
r2 put "$work/files/blob.xz" data/blobs/short.xz; expect_status 12
expect_err "R2 holds 69999 bytes after the PUT, expected 70000"
unset FAKE_AWS_FAIL

begin "the error file never reaches the output, and nothing is left behind"
export TMPDIR="$work/tmp"
mkdir -p "$TMPDIR"
export FAKE_AWS_FAIL="get-object:*:403"
r2 get data/manifest.json "$work/files/m.json"; expect_status 11
unset FAKE_AWS_FAIL
[[ -z $(ls -A "$TMPDIR") ]] || fail "temp files left: $(ls -A "$TMPDIR")"
unset TMPDIR

# --- Configuration -------------------------------------------------------------------------------

begin "missing or malformed configuration is a usage error, before any call"
run env -u AWS_SECRET_ACCESS_KEY "$r2" head data/manifest.json; expect_status 64
R2_ACCOUNT_ID='abc.evil.example/x' r2 head data/manifest.json; expect_status 64
R2_BUCKET='Bike_Ride' r2 head data/manifest.json; expect_status 64
r2 frobnicate data/x; expect_status 64
r2 get data/x; expect_status 64
r2 put "$work/files/nope.json" data/x.json; expect_status 64
r2 --help; expect_status 0
expect_no_calls

begin "R2_* key names work in place of AWS_*"
run env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY R2_ACCESS_KEY_ID="$key_id" R2_SECRET_ACCESS_KEY="$secret_key" \
  "$r2" head data/blobs/0123abcd.xz
expect_status 0

finish

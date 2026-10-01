# shellcheck shell=bash
# Shared by the script tests (sourced). Nothing here reaches the network or a real bucket: `aws`
# on PATH is scripts/test/fake-aws, the account id, keys and bucket are made up, and the tests
# stop if `aws` resolves to anything else.
#
# Every call made with run() has its stdout and stderr checked for the key pair, the account id,
# the R2 endpoint and signed-URL text, which the fake prints on every failure.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC2034 # repo and bucket are for the tests that source this file
repo=$(cd "$here/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/script-test.XXXXXX")
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin" "$work/root/test-bucket" "$work/files"
ln -s "$here/fake-aws" "$work/bin/aws"
export PATH="$work/bin:$PATH"
export FAKE_AWS_ROOT="$work/root" FAKE_AWS_LOG="$work/calls.log"
export R2_ACCOUNT_ID=0fa4e0000000000000000000000fake0 R2_BUCKET=test-bucket
key_id=AKIDFAKEKEYID00001 secret_key=fakeSecretDoNotPrint0001
export AWS_ACCESS_KEY_ID=$key_id AWS_SECRET_ACCESS_KEY=$secret_key
unset R2_DRY_RUN R2_ALLOW_PRIVATE_FLOWS FAKE_AWS_FAIL R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY GITHUB_STEP_SUMMARY
[[ $(command -v aws) == "$work/bin/aws" ]] || { echo "${0##*/}: aws is not the fake; stopping" >&2; exit 1; }
# shellcheck disable=SC2034
bucket="$work/root/test-bucket"

failures=0 tests=0 current=
fail() { echo "FAIL [$current]: $*" >&2; failures=$((failures + 1)); }
begin() { current=$1; tests=$((tests + 1)); : >"$FAKE_AWS_LOG"; }

# run COMMAND ARGS...: status, out and err of one call; then the leak check.
run() {
  set +e
  "$@" >"$work/out" 2>"$work/err"
  status=$?
  set -e
  out=$(cat "$work/out")
  err=$(cat "$work/err")
  local both="$out"$'\n'"$err" secret
  for secret in "$secret_key" "$key_id" "$R2_ACCOUNT_ID" X-Amz-Signature X-Amz-Credential \
    r2.cloudflarestorage.com DEBUG "An error occurred"; do
    [[ $both != *"$secret"* ]] || fail "output contains '$secret': $both"
  done
}

expect_status() { [[ $status -eq $1 ]] || fail "status $status, expected $1 (stderr: $err)"; }
expect_err() { [[ $err == *"$1"* ]] || fail "stderr lacks '$1': $err"; }
expect_no_calls() { [[ ! -s $FAKE_AWS_LOG ]] || fail "aws was called: $(cat "$FAKE_AWS_LOG")"; }
expect_call() { grep -q -- "$1" "$FAKE_AWS_LOG" || fail "no aws call matching '$1': $(cat "$FAKE_AWS_LOG")"; }
expect_no_call() { ! grep -q -- "$1" "$FAKE_AWS_LOG" || fail "an aws call matches '$1': $(grep -- "$1" "$FAKE_AWS_LOG")"; }

finish() {
  if [[ $failures -ne 0 ]]; then
    echo "${0##*/}: $failures failure(s) in $tests tests" >&2
    exit 1
  fi
  echo "${0##*/}: $tests tests passed"
}

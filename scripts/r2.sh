#!/usr/bin/env bash
# The only way the publishing scripts reach R2: a guarded wrapper around the pinned AWS CLI
# (2.27.0 in CI, data-build.yml). Every other script calls this one; none calls `aws` itself.
#
#   scripts/r2.sh get    <key> <file>                 download to <file> (a temp file, then renamed)
#   scripts/r2.sh head   <key>                        print "<bytes>\t<etag>\t<lastModified>"
#   scripts/r2.sh put    <file> <key> [content-type]  upload, then HEAD and compare the size
#   scripts/r2.sh list   <prefix>                     print "<key>\t<bytes>\t<lastModified>" per object
#   scripts/r2.sh delete <key>
#
# The guard (docs/publish.md, "R2"):
# - Keys and list prefixes must be under data/ or sources/, or private/flows/ when the caller sets
#   R2_ALLOW_PRIVATE_FLOWS=1 (the private flows workflow only). history/ and fixtures/ (the GBFS
#   history and the Tier B fixtures, unversioned and irreplaceable) are refused by name before the
#   allowlist is even read. Keys are plain: [A-Za-z0-9._/-], no empty, "." or ".." segment, no
#   leading or trailing slash. A list needs a prefix ending in "/": there is no unprefixed list.
# - The AWS CLI's stderr goes to a private temp file that is read only to tell the failures apart
#   and is never printed: AWS error text names keys and, with debugging on, signed URLs. On a
#   failure this prints one fixed line: the operation, the key it was given, the kind of failure
#   and the exit status.
# - Not found (NoSuchKey, 404) is told apart from access denied (403) and from everything else
#   (5xx, the network, a bad digest). Only the caller knows whether a 404 is fine (a first run's
#   manifest); a 403 or a 5xx is never "not there", so callers fail closed on them.
# - Uploads are `s3api put-object --content-md5` (R2 checks the digest), never `s3 cp`, which goes
#   multipart above 8 MB (tt-bus is 8.35 MB) and so has no whole-object MD5; each is followed by a
#   HEAD that compares ContentLength with the local size.
# - R2_DRY_RUN=1 turns put and delete into a printed plan and touches nothing; reads still run.
#
# Environment: R2_ACCOUNT_ID, R2_BUCKET, and the key pair as AWS_ACCESS_KEY_ID /
# AWS_SECRET_ACCESS_KEY (or R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY). Nothing here prints them.
#
# Exit status: 0 done; 10 not found (get, head); 11 access denied; 12 any other R2 or CLI failure,
# or a size mismatch after a PUT; 64 usage; 77 refused by the guard.
set +x
set -euo pipefail

readonly EXIT_NOT_FOUND=10 EXIT_DENIED=11 EXIT_FAILED=12 EXIT_USAGE=64 EXIT_REFUSED=77

die() { echo "r2: $1" >&2; exit "${2:-$EXIT_FAILED}"; }
usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//' >&2; exit "${1:-$EXIT_USAGE}"; }

# check_key KEY [list]: refuses (77) a key, or with "list" a list prefix, the guard does not allow.
check_key() {
  local key=$1 kind=${2:-object}
  case $key in
    history/* | fixtures/*) die "refused: ${key%%/*}/ is never touched by the publishing scripts" "$EXIT_REFUSED" ;;
  esac
  [[ ${#key} -le 512 ]] || die "refused: key longer than 512 characters" "$EXIT_REFUSED"
  [[ $key =~ ^[A-Za-z0-9._/-]+$ ]] || die "refused: key '$key' has characters outside [A-Za-z0-9._/-]" "$EXIT_REFUSED"
  case /${key%/}/ in
    *//* | */./* | */../*) die "refused: key '$key' has an empty, '.' or '..' segment" "$EXIT_REFUSED" ;;
  esac
  if [[ $kind == list ]]; then
    [[ $key == */ ]] || die "refused: list prefix '$key' must end in /" "$EXIT_REFUSED"
  else
    [[ $key != */ ]] || die "refused: key '$key' ends in /" "$EXIT_REFUSED"
  fi
  # A list may name a whole area (data/); an object key is always inside one (and never ends in /).
  case $key in
    data/* | sources/*) return 0 ;;
    private/flows/*)
      [[ ${R2_ALLOW_PRIVATE_FLOWS:-0} == 1 ]] && return 0
      die "refused: private/flows/ is for the private flows workflow only (R2_ALLOW_PRIVATE_FLOWS=1)" "$EXIT_REFUSED"
      ;;
  esac
  die "refused: '$key' is not under data/ or sources/" "$EXIT_REFUSED"
}

need_r2() {
  : "${R2_ACCOUNT_ID:?set R2_ACCOUNT_ID}" "${R2_BUCKET:?set R2_BUCKET}"
  [[ $R2_ACCOUNT_ID =~ ^[A-Za-z0-9]+$ ]] || die "R2_ACCOUNT_ID is not an account id" "$EXIT_USAGE"
  [[ $R2_BUCKET =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]] || die "R2_BUCKET is not a bucket name" "$EXIT_USAGE"
  export AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:-${R2_ACCESS_KEY_ID:-}}
  export AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-${R2_SECRET_ACCESS_KEY:-}}
  [[ -n $AWS_ACCESS_KEY_ID && -n $AWS_SECRET_ACCESS_KEY ]] || die "set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY (or R2_*)" "$EXIT_USAGE"
  command -v aws >/dev/null 2>&1 || die "AWS CLI v2 not found" "$EXIT_USAGE"
  local version
  version=$(aws --version 2>/dev/null) || true
  [[ $version == aws-cli/2.* ]] || die "need AWS CLI v2" "$EXIT_USAGE"
  # R2 rejects the CRC32 checksums the CLI adds by default since 2.23 (as compact-gbfs-history.sh).
  export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
  export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
  export AWS_PAGER=""
  ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
  ERR_DIR=$(mktemp -d "${TMPDIR:-/tmp}/r2.XXXXXX")
  chmod 700 "$ERR_DIR"
  trap 'rm -rf "$ERR_DIR"' EXIT
}

# aws_call OP KEY OUT AWS-ARGS...: runs one s3api call with its stdout in OUT (a file, or
# /dev/null) and its stderr in a private file. On failure prints the fixed line and exits 10, 11
# or 12, by the error code in that file.
aws_call() {
  local op=$1 key=$2 out=$3 err="$ERR_DIR/stderr" rc=0
  shift 3
  aws --endpoint-url "$ENDPOINT" --region auto s3api "$@" >"$out" 2>"$err" || rc=$?
  [[ $rc -eq 0 ]] && { rm -f "$err"; return 0; }
  local text kind status
  text=$(cat "$err")
  rm -f "$err"
  if [[ $text == *"(NoSuchKey)"* || $text == *"(404)"* || $text == *"(NotFound)"* ]]; then
    kind="not found" status=$EXIT_NOT_FOUND
  elif [[ $text == *"(AccessDenied)"* || $text == *"(403)"* || $text == *"(Forbidden)"* ||
    $text == *"(InvalidAccessKeyId)"* || $text == *"(SignatureDoesNotMatch)"* ]]; then
    kind="access denied" status=$EXIT_DENIED
  else
    kind="failed (aws exit $rc)" status=$EXIT_FAILED
  fi
  die "$op $key: $kind (exit $status)" "$status"
}

file_size() { wc -c <"$1" | tr -d ' '; }

# The Content-MD5 header: base64 of the binary digest. From the hex digest with printf, so
# neither openssl nor xxd is needed (the swift container has neither by default).
md5_base64() {
  local hex
  if command -v md5sum >/dev/null 2>&1; then hex=$(md5sum "$1" | cut -d' ' -f1); else hex=$(md5 -q "$1"); fi
  [[ $hex =~ ^[0-9a-f]{32}$ ]] || die "cannot hash $1"
  # shellcheck disable=SC2059 # the format is the digest as \xHH escapes
  printf "$(printf '%s' "$hex" | sed 's/../\\x&/g')" | base64
}

content_type() {
  case $1 in
    *.json) echo application/json ;;
    *.xz) echo application/x-xz ;;
    *.zip) echo application/zip ;;
    *.csv) echo text/csv ;;
    *.geojson) echo application/geo+json ;;
    *) echo application/octet-stream ;;
  esac
}

head_line() { # head_line KEY: "<bytes>\t<etag>\t<lastModified>"
  local out="$ERR_DIR/head" bytes etag modified
  aws_call head "$1" "$out" head-object --bucket "$R2_BUCKET" --key "$1" \
    --query '[ContentLength,ETag,LastModified]' --output text
  IFS=$'\t' read -r bytes etag modified <"$out" || true
  rm -f "$out"
  [[ $bytes =~ ^[0-9]+$ ]] || die "head $1: unreadable response (exit $EXIT_FAILED)"
  etag=${etag//\"/}
  printf '%s\t%s\t%s\n' "$bytes" "$etag" "$modified"
}

cmd_get() {
  [[ $# -eq 2 ]] || usage
  check_key "$1"
  need_r2
  local dest=$2 partial
  partial="$dest.r2-partial.$$"
  mkdir -p "$(dirname "$dest")"
  local rc=0
  (aws_call get "$1" /dev/null get-object --bucket "$R2_BUCKET" --key "$1" "$partial") || rc=$?
  if [[ $rc -ne 0 ]]; then
    rm -f "$partial"
    exit "$rc"
  fi
  mv -f "$partial" "$dest"
}

cmd_head() {
  [[ $# -eq 1 ]] || usage
  check_key "$1"
  need_r2
  head_line "$1"
}

cmd_put() {
  [[ $# -eq 2 || $# -eq 3 ]] || usage
  local file=$1 key=$2 type=${3:-}
  check_key "$key"
  [[ -f $file ]] || die "put: $file is not a file" "$EXIT_USAGE"
  [[ -n $type ]] || type=$(content_type "$key")
  local bytes
  bytes=$(file_size "$file")
  if [[ ${R2_DRY_RUN:-0} == 1 ]]; then
    echo "r2: [dry run] would put $key ($bytes bytes, $type)" >&2
    return 0
  fi
  need_r2
  # Hashed on its own line: set -e stops on a failed assignment, but not on a failed $(...)
  # inside a command's arguments, which would send an empty Content-MD5.
  local md5
  md5=$(md5_base64 "$file")
  aws_call put "$key" /dev/null put-object --bucket "$R2_BUCKET" --key "$key" --body "$file" \
    --content-md5 "$md5" --content-type "$type"
  local stored
  stored=$(head_line "$key" | cut -f1) || die "put $key: no HEAD after the PUT (exit $EXIT_FAILED)"
  [[ $stored == "$bytes" ]] || die "put $key: R2 holds $stored bytes after the PUT, expected $bytes (exit $EXIT_FAILED)"
  echo "r2: put $key ($bytes bytes)" >&2
}

cmd_list() {
  [[ $# -eq 1 ]] || usage
  local prefix=$1 out line key
  check_key "$prefix" list
  need_r2
  out="$ERR_DIR/list"
  # The CLI follows continuation tokens itself; an empty listing prints "None".
  aws_call list "$prefix" "$out" list-objects-v2 --bucket "$R2_BUCKET" --prefix "$prefix" \
    --query 'Contents[].[Key,Size,LastModified]' --output text
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line || $line == None ]] && continue
    key=${line%%$'\t'*}
    [[ $key == "$prefix"?* ]] || die "list $prefix: the response names a key outside the prefix (exit $EXIT_FAILED)"
    printf '%s\n' "$line"
  done <"$out"
  rm -f "$out"
}

cmd_delete() {
  [[ $# -eq 1 ]] || usage
  check_key "$1"
  if [[ ${R2_DRY_RUN:-0} == 1 ]]; then
    echo "r2: [dry run] would delete $1" >&2
    return 0
  fi
  need_r2
  aws_call delete "$1" /dev/null delete-object --bucket "$R2_BUCKET" --key "$1"
  echo "r2: deleted $1" >&2
}

[[ $# -ge 1 ]] || usage
command=$1
shift
case $command in
  get) cmd_get "$@" ;;
  head) cmd_head "$@" ;;
  put) cmd_put "$@" ;;
  list) cmd_list "$@" ;;
  delete) cmd_delete "$@" ;;
  -h | --help) usage 0 ;;
  *) die "unknown command '$command'" "$EXIT_USAGE" ;;
esac

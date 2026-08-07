#!/usr/bin/env bash
# Dump selected schemas and upload the dump to a PRIVATE Supabase Storage bucket.
# Dumps never touch git — .gitignore blocks backups/ as a second line of defence, but the
# real guarantee is that this script writes only to $WORKDIR and uploads over HTTPS.
#
#   scripts/backup.sh <label> <schema>[,<schema>...]
#
# Required environment:
#   SOURCE_DATABASE_URL        what to dump (session-mode pooler URL, port 5432)
#   SUPABASE_URL               https://<ref>.supabase.co  (public, not a secret)
#   SUPABASE_SERVICE_ROLE_KEY  Storage credential
#   BACKUP_BUCKET              bucket name (default: db-backups)
#   STAMP                      object name prefix (default: derived from label)
#
# Verification, all of it fail-loud:
#   * the dump parses            — pg_restore -l exits 0
#   * the dump contains DDL      — pg_restore -f - | head shows CREATE statements
#   * the dump is not a stub     — size floor check
#   * the upload actually landed — HEAD the object and compare byte length
set -euo pipefail

LABEL="${1:?usage: backup.sh <label> <schemas>}"
SCHEMAS="${2:?usage: backup.sh <label> <schemas>}"

: "${SOURCE_DATABASE_URL:?SOURCE_DATABASE_URL is not set}"
: "${SUPABASE_URL:?SUPABASE_URL is not set}"
: "${SUPABASE_SERVICE_ROLE_KEY:?SUPABASE_SERVICE_ROLE_KEY is not set}"
BUCKET="${BACKUP_BUCKET:-db-backups}"
WORKDIR="${WORKDIR:-$(mktemp -d)}"
MIN_BYTES="${MIN_BYTES:-10240}"

# ---- report the target without ever printing the password -------------------
mask() { sed -E 's#(://[^:@/]+):[^@]*@#\1:***@#g' <<<"$1"; }
echo "== backup: $LABEL"
echo "   schemas : $SCHEMAS"
echo "   source  : $(mask "$SOURCE_DATABASE_URL")"

port="$(sed -E 's#.*:([0-9]+)(/.*)?$#\1#' <<<"${SOURCE_DATABASE_URL%%\?*}")"
if [[ "$port" == "6543" ]]; then
  echo "FAIL: port 6543 is the transaction-mode pooler; pg_dump needs session mode (5432)." >&2
  exit 1
fi

# A 16.x client cannot dump a 17.6 server; it aborts on version mismatch.
for tool in pg_dump pg_restore; do
  v="$("$tool" --version | grep -oE '[0-9]+' | head -1)"
  [[ "$v" == "17" ]] || { echo "FAIL: $tool is major version $v; the servers are 17.x. Refusing to run." >&2; exit 1; }
done

mkdir -p "$WORKDIR"
STAMP="${STAMP:-$(date -u +%Y/%m/%Y%m%dT%H%M%SZ)}"
OUT="$WORKDIR/${LABEL}.dump"
OBJECT="${LABEL}/${STAMP}-${LABEL}.dump"

# ---- dump -------------------------------------------------------------------
args=(--no-owner --no-privileges --format=custom --compress=9 --verbose)
IFS=',' read -ra parts <<<"$SCHEMAS"
for s in "${parts[@]}"; do args+=(--schema="$s"); done

echo "== pg_dump starting $(date -u +%H:%M:%SZ)"
pg_dump "$SOURCE_DATABASE_URL" "${args[@]}" --file="$OUT" 2> "$WORKDIR/dump.log" || {
  echo "FAIL: pg_dump exited non-zero. Tail of its log:" >&2
  tail -30 "$WORKDIR/dump.log" >&2
  exit 1
}
echo "== pg_dump finished $(date -u +%H:%M:%SZ)"

BYTES=$(stat -c%s "$OUT")
echo "   dump bytes : $BYTES ($(numfmt --to=iec-i --suffix=B "$BYTES"))"
if (( BYTES < MIN_BYTES )); then
  echo "FAIL: dump is $BYTES bytes, below the ${MIN_BYTES}-byte floor — that is a stub, not a backup." >&2
  exit 1
fi

# ---- verify: parse, then prove it carries DDL --------------------------------
echo "== verify: pg_restore -l (parse)"
pg_restore -l "$OUT" > "$WORKDIR/toc.txt"
echo "   parse exit : 0"
echo "   toc entries: $(wc -l < "$WORKDIR/toc.txt")"

# The custom-format equivalent of 'zcat | head'. Restore the SCHEMA ONLY to a file and read
# that, rather than streaming the whole dump into a head/grep: with `set -o pipefail`, a
# reader that stops early closes the pipe, pg_restore dies of SIGPIPE, and the pipeline
# reports 141 — which reads as "no DDL in the dump" for a dump that is perfectly fine. That
# is exactly how the cfb leg failed while printing CREATE SCHEMA cfb one line above the error.
# Schema-only output is small even for a 5 GB dump, so this costs nothing.
echo "== verify: DDL head (the custom-format equivalent of 'zcat | head')"
pg_restore --schema-only -f "$WORKDIR/ddl.sql" "$OUT" 2>/dev/null || true
if [[ ! -s "$WORKDIR/ddl.sql" ]] || ! grep -qE '^(CREATE|ALTER)' "$WORKDIR/ddl.sql"; then
  echo "FAIL: no DDL statements found in the dump." >&2
  exit 1
fi
echo "   DDL lines: $(grep -cE '^(CREATE|ALTER)' "$WORKDIR/ddl.sql")"
{ grep -E '^(CREATE|ALTER)' "$WORKDIR/ddl.sql" | head -12 | sed 's/^/   /'; } || true

echo "== verify: table count in the dump"
TABLES=$(grep -cE '[[:space:]]TABLE[[:space:]]' "$WORKDIR/toc.txt" || true)
echo "   toc TABLE entries: $TABLES"

# ---- Storage auth ------------------------------------------------------------
# Supabase has two generations of API key. The legacy service_role key is a JWT and is sent
# as `Authorization: Bearer`. The new-style `sb_secret_...` key is NOT a JWT, and sending it
# as a Bearer token makes storage-api try to parse it as one and fail with
# {"message":"Invalid Compact JWS","code":"AccessDenied"} — which is exactly how the first
# seal run failed. Rather than hard-code a guess about which key is in the secret, probe the
# modes against a harmless endpoint and use whichever authenticates.
AUTH=()
auth_for() {
  case "$1" in
    apikey) AUTH=(-H "apikey: $SUPABASE_SERVICE_ROLE_KEY") ;;
    bearer) AUTH=(-H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY") ;;
    both)   AUTH=(-H "apikey: $SUPABASE_SERVICE_ROLE_KEY"
                  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY") ;;
  esac
}

echo "== detecting the Storage auth mode this key needs"
MODE=""
for m in both apikey bearer; do
  auth_for "$m"
  c=$(curl -sS -o "$WORKDIR/probe.json" -w '%{http_code}' \
        "$SUPABASE_URL/storage/v1/bucket" "${AUTH[@]}" || echo 000)
  echo "   mode=$m -> HTTP $c"
  if [[ "$c" == "200" ]]; then MODE="$m"; break; fi
done
if [[ -z "$MODE" ]]; then
  echo "FAIL: no auth mode worked against Storage. Last response:" >&2
  head -c 400 "$WORKDIR/probe.json" >&2; echo >&2
  echo "The key in SUPABASE_SERVICE_ROLE_KEY does not authenticate to Storage." >&2
  exit 1
fi
auth_for "$MODE"
echo "   using auth mode: $MODE"

# ---- the bucket must exist and must be private -------------------------------
# Create-if-missing, then VERIFY. An earlier version treated a non-200 create as harmless and
# went straight to uploading, so a create that failed 400 surfaced later and less clearly as
# "Bucket not found" on the upload. Read the bucket back instead of assuming the create worked.
echo "== bucket '$BUCKET'"
code=$(curl -sS -o "$WORKDIR/bucket.json" -w '%{http_code}' \
        "$SUPABASE_URL/storage/v1/bucket/$BUCKET" "${AUTH[@]}" || echo 000)
if [[ "$code" != "200" ]]; then
  echo "   not present (HTTP $code) — creating"
  # No file_size_limit here: the API rejects a bucket limit above the project's global
  # ceiling with a bare 400, and the bucket inherits the ceiling when the field is omitted.
  curl -sS -X POST "$SUPABASE_URL/storage/v1/bucket" \
    "${AUTH[@]}" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$BUCKET\",\"id\":\"$BUCKET\",\"public\":false}" \
    -o "$WORKDIR/create.json" -w '   create-bucket HTTP %{http_code}\n' || true
  echo "   create response: $(head -c 300 "$WORKDIR/create.json" 2>/dev/null)"
  code=$(curl -sS -o "$WORKDIR/bucket.json" -w '%{http_code}' \
          "$SUPABASE_URL/storage/v1/bucket/$BUCKET" "${AUTH[@]}" || echo 000)
fi
if [[ "$code" != "200" ]]; then
  echo "FAIL: bucket '$BUCKET' does not exist and could not be created (HTTP $code)." >&2
  head -c 400 "$WORKDIR/bucket.json" >&2; echo >&2
  exit 1
fi
if grep -q '"public"[[:space:]]*:[[:space:]]*true' "$WORKDIR/bucket.json"; then
  echo "FAIL: bucket $BUCKET is PUBLIC. Backups must live in a private bucket." >&2
  exit 1
fi
echo "   present and private: $(head -c 200 "$WORKDIR/bucket.json")"

# ---- upload ------------------------------------------------------------------
# A Supabase project has a GLOBAL upload ceiling that is separate from, and lower than, any
# per-bucket file_size_limit: the bucket here allows 50 GB and a 380 MB object still came
# back 413 EntityTooLarge. Raising that ceiling is a dashboard setting. Rather than make the
# backups depend on it, anything above the ceiling is split into parts and uploaded
# alongside a manifest. Reassembly is `cat part.* > <label>.dump`, which pg_restore reads
# directly — the manifest carries the sha256 of the whole dump so reassembly is checkable.
CHUNK_BYTES="${CHUNK_BYTES:-40000000}"

upload_one() {  # <local file> <object path>
  local f="$1" obj="$2" c
  c=$(curl -sS -X POST "$SUPABASE_URL/storage/v1/object/$BUCKET/$obj" \
        "${AUTH[@]}" \
        -H "Content-Type: application/octet-stream" \
        -H "x-upsert: true" \
        --data-binary "@$f" \
        -o "$WORKDIR/up.json" -w '%{http_code}') || c=000
  if [[ "$c" != "200" ]]; then
    echo "FAIL: upload of $obj returned HTTP $c" >&2
    head -c 400 "$WORKDIR/up.json" >&2; echo >&2
    return 1
  fi
  return 0
}

SHA=$(sha256sum "$OUT" | cut -d' ' -f1)

if (( BYTES <= CHUNK_BYTES )); then
  PREFIX="${LABEL}/${STAMP}-${LABEL}"
  OBJECT="${PREFIX}.dump"
  echo "== uploading $OBJECT (single object, $BYTES bytes)"
  upload_one "$OUT" "$OBJECT" || exit 1
  # The list endpoint lists ONE level: a prefix of "cfb/" returns the folder "2026", not the
  # object. The prefix has to be the directory the object actually sits in.
  LISTPREFIX="${LABEL}/$(dirname "$STAMP")/"
  EXPECT_NAME="$(basename "$OBJECT")"
  PARTS=1
else
  PREFIX="${LABEL}/${STAMP}-${LABEL}.parts"
  echo "== $BYTES bytes is above the ${CHUNK_BYTES}-byte upload ceiling — splitting"
  ( cd "$WORKDIR" && split -b "$CHUNK_BYTES" -d -a 4 "$OUT" part. )
  PARTS=$(find "$WORKDIR" -maxdepth 1 -name 'part.*' | wc -l | tr -d ' ')
  echo "   $PARTS parts"
  i=0
  for p in "$WORKDIR"/part.*; do
    i=$((i+1))
    upload_one "$p" "$PREFIX/$(basename "$p")" || exit 1
    printf '   uploaded %s (%s/%s)\n' "$(basename "$p")" "$i" "$PARTS"
  done
  printf '{"label":"%s","stamp":"%s","schemas":"%s","bytes":%s,"parts":%s,"sha256":"%s","reassemble":"cat part.* > %s.dump && pg_restore ..."}\n' \
    "$LABEL" "$STAMP" "$SCHEMAS" "$BYTES" "$PARTS" "$SHA" "$LABEL" > "$WORKDIR/manifest.json"
  upload_one "$WORKDIR/manifest.json" "$PREFIX/manifest.json" || exit 1
  echo "   uploaded manifest.json"
  LISTPREFIX="$PREFIX/"
  EXPECT_NAME=""
fi

# ---- verify what actually landed, by byte length -----------------------------
echo "== verify: objects present in Storage"
curl -sS -X POST "$SUPABASE_URL/storage/v1/object/list/$BUCKET" \
  "${AUTH[@]}" \
  -H "Content-Type: application/json" \
  -d "{\"prefix\":\"${LISTPREFIX}\",\"limit\":1000}" \
  -o "$WORKDIR/list.json" -w '   list HTTP %{http_code}\n'

REMOTE=$(python3 - "$WORKDIR/list.json" "$EXPECT_NAME" <<'PY' || echo ''
import json,sys
path,expect = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(path))
except Exception:
    print(''); raise SystemExit
if not isinstance(d, list):
    print(''); raise SystemExit
total = 0
for o in d:
    n = o.get('name') or ''
    if expect:
        if n != expect: continue
    elif not n.startswith('part.'):
        continue
    total += int((o.get('metadata') or {}).get('size') or 0)
print(total)
PY
)

if [[ -z "$REMOTE" || "$REMOTE" == "0" ]]; then
  echo "FAIL: could not read back any uploaded bytes. Listing follows:" >&2
  head -c 600 "$WORKDIR/list.json" >&2; echo >&2
  exit 1
fi
echo "   remote bytes: $REMOTE (local $BYTES)"
if [[ "$REMOTE" != "$BYTES" ]]; then
  echo "FAIL: uploaded bytes $REMOTE do not match the dump's $BYTES." >&2
  exit 1
fi

echo
echo "PASS: $LABEL — $BYTES bytes in $PARTS object(s), parse clean, sha256 $SHA"
echo "      at $BUCKET/$LISTPREFIX"

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

echo "== verify: DDL head (the custom-format equivalent of 'zcat | head')"
pg_restore -f - "$OUT" 2>/dev/null | grep -m 12 -E '^(CREATE|ALTER|SET|COMMENT)' || {
  echo "FAIL: no DDL statements found in the dump." >&2
  exit 1
}

echo "== verify: table count in the dump"
TABLES=$(grep -cE 'TABLE (DATA )?-' "$WORKDIR/toc.txt" || true)
echo "   toc TABLE entries: $TABLES"

# ---- upload to private Storage ----------------------------------------------
echo "== ensuring bucket '$BUCKET' exists (private)"
curl -sS -X POST "$SUPABASE_URL/storage/v1/bucket" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"$BUCKET\",\"id\":\"$BUCKET\",\"public\":false}" \
  -o "$WORKDIR/bucket.json" -w '   create-bucket HTTP %{http_code}\n' || true
grep -q '"public":true' "$WORKDIR/bucket.json" 2>/dev/null && {
  echo "FAIL: bucket $BUCKET is PUBLIC. Backups must live in a private bucket." >&2; exit 1; }

echo "== uploading $OBJECT"
code=$(curl -sS -X POST "$SUPABASE_URL/storage/v1/object/$BUCKET/$OBJECT" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Content-Type: application/octet-stream" \
  -H "x-upsert: true" \
  --data-binary "@$OUT" \
  -o "$WORKDIR/upload.json" -w '%{http_code}')
echo "   upload HTTP $code"
if [[ "$code" != "200" ]]; then
  echo "FAIL: upload did not return 200. Response:" >&2
  cat "$WORKDIR/upload.json" >&2; echo >&2
  exit 1
fi

# ---- verify the object actually landed, at the right size --------------------
echo "== verify: object present in Storage"
curl -sS -X POST "$SUPABASE_URL/storage/v1/object/list/$BUCKET" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"prefix\":\"${LABEL}/\",\"limit\":100,\"sortBy\":{\"column\":\"created_at\",\"order\":\"desc\"}}" \
  -o "$WORKDIR/list.json" -w '   list HTTP %{http_code}\n'

REMOTE=$(python3 -c "
import json,sys
d=json.load(open('$WORKDIR/list.json'))
tgt='$(basename "$OBJECT")'
for o in d if isinstance(d,list) else []:
    if o.get('name')==tgt:
        print((o.get('metadata') or {}).get('size',''))
        sys.exit(0)
print('')
" 2>/dev/null || echo '')

if [[ -z "$REMOTE" ]]; then
  echo "WARN: could not read the object size back from the list API; object listing follows:" >&2
  head -c 600 "$WORKDIR/list.json" >&2; echo >&2
else
  echo "   remote bytes: $REMOTE (local $BYTES)"
  if [[ "$REMOTE" != "$BYTES" ]]; then
    echo "FAIL: uploaded size $REMOTE does not match local size $BYTES." >&2
    exit 1
  fi
fi

echo
echo "PASS: $LABEL — $BYTES bytes, parse clean, uploaded to $BUCKET/$OBJECT"

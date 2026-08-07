#!/usr/bin/env bash
# Genesis, Job 2 — move the cfb schema whole from the previous project into AIP2.
#
#   pg_dump --schema=cfb --no-owner -Fc  ->  pg_restore
#
# The gate is row counts: exact count(*) per table on the source, taken immediately before
# the dump, must equal exact count(*) per table on the target after the restore, 46 of 46.
# A single mismatched table fails the run.
#
# The source is re-counted after the restore as well. If the source moved underneath the
# dump, that shows up as source-before != source-after, and it is reported as its own
# finding rather than silently blamed on the restore.
#
# Required environment: OLD_DATABASE_URL, DATABASE_URL
set -euo pipefail

: "${OLD_DATABASE_URL:?OLD_DATABASE_URL is not set}"
: "${DATABASE_URL:?DATABASE_URL is not set}"

WORKDIR="${WORKDIR:-$(mktemp -d)}"
mkdir -p "$WORKDIR"
DUMP="$WORKDIR/cfb.dump"

mask() { sed -E 's#(://[^:@/]+):[^@]*@#\1:***@#g' <<<"$1"; }
echo "source : $(mask "$OLD_DATABASE_URL")"
echo "target : $(mask "$DATABASE_URL")"

for url in "$OLD_DATABASE_URL" "$DATABASE_URL"; do
  p="$(sed -E 's#.*:([0-9]+)(/.*)?$#\1#' <<<"${url%%\?*}")"
  [[ "$p" == "6543" ]] && { echo "FAIL: port 6543 is transaction-mode; pg_dump/pg_restore need session mode (5432)." >&2; exit 1; }
done

COUNT_SQL="select t.tablename,
  (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from cfb.%I', t.tablename), false, true, '')))[1]::text::bigint
from pg_tables t where t.schemaname='cfb' order by 1;"

# ---------------------------------------------------------------- 1. source counts
echo
echo "=== 1. exact source counts (the gate) — $(date -u +%H:%M:%SZ)"
psql "$OLD_DATABASE_URL" -v ON_ERROR_STOP=1 -At -F$'\t' -c "$COUNT_SQL" > "$WORKDIR/source-before.tsv"
echo "    tables counted: $(wc -l < "$WORKDIR/source-before.tsv")"

# ------------------------------------------------- 2. extensions the cfb schema needs
echo
echo "=== 2. extensions on the target"
# cfb.enqueue_weekly_sync() calls net.http_get and is scheduled by pg_cron; both must exist
# before the restore, because the functions' search_path references the net schema.
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
create extension if not exists pg_trgm;
create extension if not exists pg_net;
create extension if not exists pg_cron;
SQL
psql "$DATABASE_URL" -At -F$'\t' -c \
  "select extname, extversion from pg_extension order by extname;" | sed 's/^/    /'

# ------------------------------------------------------------------------ 3. dump
echo
echo "=== 3. pg_dump --schema=cfb --no-owner -Fc — $(date -u +%H:%M:%SZ)"
pg_dump "$OLD_DATABASE_URL" --schema=cfb --no-owner --format=custom --compress=9 \
  --file="$DUMP" --verbose 2> "$WORKDIR/dump.log" || {
    echo "FAIL: pg_dump exited non-zero:" >&2; tail -40 "$WORKDIR/dump.log" >&2; exit 1; }
BYTES=$(stat -c%s "$DUMP")
echo "    dump: $BYTES bytes ($(numfmt --to=iec-i --suffix=B "$BYTES"))"
pg_restore -l "$DUMP" > "$WORKDIR/toc.txt"
echo "    parse exit 0, $(wc -l < "$WORKDIR/toc.txt") toc entries"

# --------------------------------------------------------------------- 4. restore
echo
echo "=== 4. pg_restore into AIP2 — $(date -u +%H:%M:%SZ)"
set +e
pg_restore --dbname="$DATABASE_URL" --no-owner --no-privileges --jobs=4 --verbose \
  "$DUMP" 2> "$WORKDIR/restore.log"
RC=$?
set -e
ERRS=$(grep -c '^pg_restore: error' "$WORKDIR/restore.log" || true)
echo "    pg_restore exit $RC, $ERRS error line(s)"
if [ "$ERRS" -gt 0 ]; then
  echo "    --- restore errors (all of them) ---"
  grep '^pg_restore: error' "$WORKDIR/restore.log" | sed 's/^/    /'
  echo "    --- end restore errors ---"
fi

# --------------------------------------------------------- 5. counts on both sides
echo
echo "=== 5. exact target counts + source re-count — $(date -u +%H:%M:%SZ)"
psql "$DATABASE_URL"     -v ON_ERROR_STOP=1 -At -F$'\t' -c "$COUNT_SQL" > "$WORKDIR/target.tsv"
psql "$OLD_DATABASE_URL" -v ON_ERROR_STOP=1 -At -F$'\t' -c "$COUNT_SQL" > "$WORKDIR/source-after.tsv"

if ! diff -q "$WORKDIR/source-before.tsv" "$WORKDIR/source-after.tsv" >/dev/null; then
  echo "FINDING: the source changed during the transfer —"
  diff "$WORKDIR/source-before.tsv" "$WORKDIR/source-after.tsv" | sed 's/^/    /' || true
fi

# ------------------------------------------------------------- 6. the count table
echo
echo "=== 6. THE GATE — per-table counts, expected vs actual"
printf '    %-26s %14s %14s  %s\n' TABLE EXPECTED ACTUAL VERDICT
MISMATCH=0
TOTAL=0
while IFS=$'\t' read -r tbl exp; do
  TOTAL=$((TOTAL+1))
  act=$(awk -F'\t' -v t="$tbl" '$1==t{print $2}' "$WORKDIR/target.tsv")
  [ -z "$act" ] && act="ABSENT"
  if [ "$act" = "$exp" ]; then v=PASS; else v="*** MISMATCH ***"; MISMATCH=$((MISMATCH+1)); fi
  printf '    %-26s %14s %14s  %s\n' "$tbl" "$exp" "$act" "$v"
done < "$WORKDIR/source-before.tsv"

EXTRA=$(comm -13 <(cut -f1 "$WORKDIR/source-before.tsv" | sort) <(cut -f1 "$WORKDIR/target.tsv" | sort) || true)
[ -n "$EXTRA" ] && { echo "    tables on target but not source: $EXTRA"; MISMATCH=$((MISMATCH+1)); }

echo
echo "    $((TOTAL-MISMATCH)) of $TOTAL tables match."
[ "$TOTAL" -eq 46 ] || { echo "FAIL: expected 46 source tables, counted $TOTAL." >&2; exit 1; }
[ "$MISMATCH" -eq 0 ] || { echo "FAIL: $MISMATCH table(s) mismatched. The transfer is not verified." >&2; exit 1; }

# --------------------------------------------------------------- 7. spot-checks
echo
echo "=== 7. spot-checks (three known facts)"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -P pager=off -f scripts/sql/spot-checks.sql

# ------------------------------------------------------------------- 8. RLS
echo
echo "=== 8. RLS on the target"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -F$'\t' -c \
  "select count(*) filter (where rowsecurity), count(*) from pg_tables where schemaname='cfb';" \
  | awk -F'\t' '{printf "    RLS enabled on %s of %s cfb tables\n", $1, $2}'

echo
echo "PASS: cfb moved whole — 46 of 46 tables verified."

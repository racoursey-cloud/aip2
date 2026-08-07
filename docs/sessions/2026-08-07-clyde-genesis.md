# Session record — Clyde, genesis (August 7, 2026)

Executing `claude/assignment-clyde-2026-08-09-genesis.md`, RATIFIED by Robert on August 7
(docs.rulings #9: "Greenfield ruled, full version" · "AIP2 name for project and repo"). The
assignment is carried into this repository at `docs/assignments/2026-08-09-genesis.md`.

The order's title in the old record still reads "DRAFT, awaiting ratification". That title is
stale: ruling #9 names this exact path and ratifies it as drafted, and the document body says
RATIFIED. Checked before executing, because a draft would have been held.

---

## STOP battery — every check, expected vs actual

### Pinned state (verified before Job 1)

| check | pinned | actual | verdict |
|---|---|---|---|
| old project | `gyohjlarhlzeufsusvpq` ACTIVE_HEALTHY | ACTIVE_HEALTHY | PASS |
| `cfb` tables / size | 46 / 5,096 MB | 46 / 5,096 MB | PASS |
| last sync | Aug 4 | Aug 4 20:23, last row id 135 | PASS |
| 2026 season | 1,638 games | 1,638 | PASS |
| old repo | `racoursey-cloud/ai-pickens`, private | unauthenticated fetch → HTTP 403 | PASS |
| new repo | `racoursey-cloud/aip2`, PUBLIC | public, empty, default branch `main` | PASS |
| new project | AIP2 | `kfgyzwxbxffhvckxmose`, PG 17.6, us-west-2 | PASS |
| Vault `cfbd_api_key` | placed by Robert | present | PASS |
| Actions secrets | 3 placed | all three resolved in-run | PASS |
| Actions enabled | yes | workflows registered and firing | PASS |
| `cfb` per-table counts | the seed's 46-row envelope | 42 match, **4 differ** | **FINDING 1** |

### Job 1 — scaffold

| check | expected | actual | verdict |
|---|---|---|---|
| literal grep (`eyJ`, `sk-`, `postgres://`, `postgresql://`) | zero secrets | 9 hits, every one explained below | PASS |
| credential-shaped scan | clean | 29 files, 8 patterns, no match | PASS |
| repo public | unauthenticated README fetch | HTTP 200, 2,270 bytes | PASS |
| repo public | unauthenticated `git ls-remote` | succeeds with no credentials | PASS |
| workflows in Actions | 2 named | 4 present (`ci`, `db-backup`, `genesis-transfer`, `genesis-seal`) | PASS |
| CI: no secrets | green | success | PASS |
| CI: migrations on empty PG17 | green | success | PASS |
| CI: site builds | green | success | PASS |

The literal grep hits are: the assignment text quoting the four patterns; the scanner and its
pattern file, which necessarily contain them; `scripts/README.md` explaining them; and one
accident — working rule 11 contains the phrase "do-more-a**sk-l**ess". No secret is present.
The gate that actually runs matches the *shape* of a live credential, which is why this
repository can discuss `postgres://` in the open and still fail a build on a pasted value.

### Job 2 — cfb moved whole

| check | expected | actual | verdict |
|---|---|---|---|
| per-table counts | 46 of 46 exact | **46 of 46 exact**, 18,939,897 rows both sides | PASS |
| source stable during transfer | before == after | identical | PASS |
| series spot-check | 12 meetings, 6–6 | 12 meetings, 6–6 | PASS |
| rivalry spot-check | 2026-11-14 exists | Georgia Southern at Georgia State, Center Parc Stadium | PASS |
| 2013 spot-check | the win at Florida | 1 game, Georgia Southern 26 Florida 20 | PASS |
| 2026 season | 1,638 games | 1,638 | PASS |
| RLS | deny-all as today | 46/46 row security on, 0 policies | PASS |
| restored size | — | 4,229 MB (smaller than source: a fresh restore has no dead tuples) | noted |

### Job 3 — site + ops, and the sync

| check | expected | actual | verdict |
|---|---|---|---|
| migration file in repo same session | yes | `0001`, `0002` committed | PASS |
| `site` + `ops` tables | 8 | 8 | PASS |
| RLS on site/ops | deny-all | 8/8 on, 0 policies | PASS |
| working rules seeded | "10 rules" | **11** | **FINDING 2** |
| `site.picks` insert-only | enforced | UPDATE blocked, DELETE blocked (tested, rolled back) | PASS |
| `cfbd-sync` redeployed | yes | version 2, ACTIVE | PASS (but see FINDING 3) |
| sync schedule | 3 cfb entries | 3, matching the old schedules exactly | PASS |
| one sync cycle green | green | `processed=43 errors=0 lost=0 halted=queue_empty` | PASS |
| sync log row in new project | reported | 44 rows, all `ok`, 6,571 rows affected | PASS |

### Job 4 — backups and the seal

Recorded in the status note; the seal's own run reports the three dumps, their byte sizes,
their parse results and the Storage objects.

---

## Findings

**1. The cfb pin table was built with the wrong instrument.** Four tables read below the
seed's envelope: `game_player_stats` (6,682,656 pinned vs 6,697,343 actual), `play_stats`
(4,002,582 vs 4,038,150), `plays` (3,706,396 vs 3,708,477), `team_records` (18,508 vs 19,176).
The data did not move. For all four, the pinned number equals `pg_stat_user_tables.n_live_tup`
**exactly** — a planner statistic, not a count — and `cfb.sync_log` shows no write to cfb since
August 4 (its own row count, 135, matches the pin). The seed anticipated this by calling its
table "the sanity envelope, not the gate" and making exact dump-time counts the gate; that gate
was enforced and passed 46 of 46. The correction belongs to the seed, not the database.

**2. Eleven working rules, not ten.** The assignment says ten and checks for ten. The genesis
seed, filed an hour later, lists rules 1–9, then "10a — answer-the-question", marked
*"seed as the ELEVENTH rule"*, then rule 10, ddl-exported-same-session. Eleven are seeded, the
later document winning. Rule 11 is the one that says to answer the question and take no action
without explicit approval, so dropping it for a count would have been a poor trade.

**3. `cfbd-sync` does not work, and did not work before the move.** It writes to
`public.stage_json` and calls `public.flush_json` / `public.flush_drives`. None of the three
exists in either project — checked against `pg_tables` and `pg_proc`, zero rows for all three.
Any invocation fails at the first staging write. The live weekly sync is
`cfb.enqueue_weekly_sync()` and `cfb.process_sync_responses()` on pg_cron and pg_net, which
travel inside the schema dump. The function was redeployed because the order says to, and its
source is now in the repository with this finding beside it; **retiring or repairing it wants a
ruling**, and it should not be quietly left to rot a second time.

**4. A green check that had run nothing.** The first transfer reported success and moved
nothing. `pg_dump` had aborted immediately —

    pg_dump: error: aborting because of server version mismatch
    pg_dump: detail: server version: 17.6; pg_dump version: 16.14

— because installing `postgresql-client-17` was not enough: Debian's wrapper resolved `psql` to
17.10 while `pg_dump` stayed on the runner's bundled 16.14. `transfer-cfb.sh` detected this
correctly and exited 1. The workflow lost it: the step piped the script through `tee` under
`bash -e`, which takes a pipeline's status from its last command, so `tee`'s success became the
job's success. Fixed three ways — a composite action that installs the client and then
*verifies* all three binaries report 17; `set -o pipefail` on the step; and version guards
inside the scripts, so the check does not depend on the workflow being right. Recorded here
because it is the exact failure the assignment warns about: a passed check that was assumed.

**5. AIP2 went read-only for about five minutes.** Twenty-five seconds after the restore
finished, the Postgres log shows `received SIGHUP` and
`parameter "default_transaction_read_only" changed to "on"` — platform disk-pressure
protection, with 4.2 GB restored and ~2.2 GB of WAL. It cleared on its own when the disk grew.
No spend decision needed, but the capacity fact is worth keeping: cfb tripped disk protection
on day one.

**6. The service-role key is not a JWT.** The first seal run dumped correctly and then failed
every Storage call with `403 {"message":"Invalid Compact JWS"}`. `SUPABASE_SERVICE_ROLE_KEY` is
a new-style `sb_secret_` key; sent as `Authorization: Bearer`, storage-api tries to parse it as
a JWT and rejects it. `backup.sh` now probes the auth modes and uses whichever authenticates,
so it works with either key generation. The mode that works is **both headers**: `apikey`
alongside `Authorization`.

**7. A check that inverted on large input.** The seal's "does this dump contain DDL" check
streamed `pg_restore` into `grep -m 12`. grep exits at its twelfth match and closes the pipe,
`pg_restore` takes SIGPIPE and dies 141, and `set -o pipefail` turns that into a failure — so
the cfb leg reported "no DDL statements found" on the line after it had printed
`CREATE SCHEMA cfb` from that very dump. site+ops passed only because its schema emits fewer
than twelve matching lines. A check that works on the small case and inverts on the large one
is worse than no check. It now restores schema-only to a file and reads the file.

Findings 4 and 7 are the same mistake twice: **a pipeline's exit status not meaning what the
surrounding code assumed.** Both are fixed at the source.

**8. Storage has two size limits, and the one that bites is invisible from SQL.** The bucket
was created with a 50 GB `file_size_limit` and reports it back, and a 380 MB upload was still
refused with `413 EntityTooLarge`. A Supabase *project* carries a separate global upload
ceiling, lower than any bucket's, and raising it is a dashboard setting. Backups now split
above the ceiling into parts plus a manifest (byte count, part count, sha256 of the whole
dump); reassembly is `cat part.* > <label>.dump`, documented in `scripts/README.md`. This is
the better property anyway: the thing that exists to survive bad days should not depend on a
console toggle. **If Robert would rather have single-object backups**, raising the project's
upload limit and setting `CHUNK_BYTES` above the largest dump restores that behaviour with no
code change.

---

## What is open, ranked

1. **A ruling on `cfbd-sync`** — repair it or retire it (finding 3).
2. **Merge to `main`.** Genesis is on `claude/assignment-clyde-genesis-ed85g6`. Until it lands,
   `main` is empty, which is why `genesis-transfer.yml` and `genesis-seal.yml` carry push
   triggers on sentinel files: `workflow_dispatch` is only offered for workflows already on the
   default branch. Both are temporary and should be deleted after the merge, leaving
   `db-backup.yml` as the permanent scheduled job.
3. **Robert's two clicks**, after the seal's archive dump verifies: pause the old project, and
   archive the old repo.
4. **Correct the seed's pin table** to exact counts, so the next reader is not misled (finding 1).
5. **Wave 1** — the site, the rivalry page, by ~Aug 15. Season opens Aug 27; first covered
   games Sep 4–5; the rivalry Nov 14.

## Deliberate omissions

- The three `voice` cron entries are **not** recreated in AIP2. The voice schema is not carried;
  it stays in the sealed archive, and transcript retrieval is rebuilt in Wave 2 with yt-dlp.
- Migration `0001` takes **no foreign keys into cfb**. cfb arrives by restore, not by migration,
  and a migration that depended on it could not be applied to an empty database — which would
  cost the property that makes the repository able to rebuild the database.
- The grading view over `site.picks` is deferred to a later migration, for the same reason: it
  needs cfb to exist.

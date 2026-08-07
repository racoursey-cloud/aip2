# AIP2 — The A.I. Pickens Report

A college-football publication and the machinery that produces it. A weekly loop assembles a
brief from a 46-table college-football database, publishes a pregame piece and a set of graded
picks with the line frozen at pick time, records what a human actually observed during the
broadcast, and grades itself on the record afterward. This repository holds **all** of it — the
site, the database migrations, the edge functions, the operating documents, and the session
records — so the database can be rebuilt from the repository at any commit.

## Layout

| path | what lives there |
|---|---|
| `site/` | the application (Next.js, server-rendered, reads Supabase server-side) |
| `supabase/migrations/` | every schema change, in order, numbered — the database's source of truth |
| `supabase/functions/` | edge functions |
| `scripts/` | operational scripts (verification, transfer, backup helpers) |
| `docs/` | charter, editorial standard, assignments, status notes, session records |
| `.github/workflows/` | CI and the backup job |

## The one law

**Nothing rights-flagged and no secret ever enters this repository.** Third-party text lives in
the sealed archive only. Secrets live in GitHub Actions secrets and Supabase Vault only, and are
referenced by name. This repository is public from birth and must stay publishable at every
commit. `ci.yml` enforces the secret half of that on every push.

Database backups go to a **private Supabase Storage bucket, never to git** (`.gitignore` blocks
`backups/` as a second line of defence).

## Database

Two schema families, both `RLS deny-all` with server-side access only:

- **`cfb`** — the carried asset: 46 tables of college-football history, moved whole from the
  previous project and verified row-for-row. Synced weekly by `cfb.enqueue_weekly_sync()` and
  `cfb.process_sync_responses()` on `pg_cron`, which fetch through `pg_net` using a CFBD key
  held in Supabase Vault.
- **`site` + `ops`** — the publication's own data (editions, pieces, briefs, observations,
  insert-only picks) and its thin operating state (working rules, session log, rulings).

## Status

Genesis. See `docs/sessions/` for what each session did and `docs/status/` for where things stand.

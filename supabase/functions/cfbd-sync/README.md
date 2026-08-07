# cfbd-sync

Carried across from the previous project at genesis so the code exists somewhere other than
a deployed function. **Read the finding below before relying on it.**

## Finding, August 7 2026 (Clyde, genesis)

`index.ts` does not work, and did not work in the previous project either. It writes staged
records with:

```ts
await sql`insert into public.stage_json (domain, payload) ...`
const res = await sql`select public.flush_json(${domain}) as n`
```

None of `public.stage_json`, `public.flush_json` or `public.flush_drives` exist in the
previous project — checked against `pg_tables` and `pg_proc`, zero rows for all three. Any
invocation fails at the first `stageFlush` call.

## What actually syncs the data

The live path is **not** this function. It is two `SECURITY DEFINER` functions inside the
`cfb` schema, driven by `pg_cron` and `pg_net`:

| cron | command |
|---|---|
| `0 9 * * 1` | `select cfb.enqueue_weekly_sync()` |
| `2-59/5 9-11 * * 1` | `select cfb.process_sync_responses()` |
| `0,15,30 13 * * 1` | `select cfb.process_sync_responses()` |

`cfb.enqueue_weekly_sync()` reads the CFBD key from Vault
(`vault.decrypted_secrets`, name `cfbd_api_key`), fires ~44 `net.http_get` calls, and records
each one in `cfb.sync_requests`. `cfb.process_sync_responses()` then drains `net._http_response`
into the cfb tables. Both travel with the schema in a `pg_dump --schema=cfb`, so the working
sync moved across with the data; it needs `pg_net` and `pg_cron` present, which the transfer
script creates before restoring.

That is why the weekly sync is exercised through those functions and not through this one.

## Before this function is used again

Either restore the missing staging objects, or — better — retire the file. It duplicates a
job the in-database path already does, and the duplication is what let it rot unnoticed.
Decide deliberately rather than by deploying it.

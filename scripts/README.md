# scripts

| script | what it does |
|---|---|
| `scan-secrets.sh` | fails if anything credential-shaped is tracked. Runs in `ci.yml` on every push. |
| `secret-patterns.txt` | the patterns that gate above. They match the *shape* of a live secret, so documentation can discuss `postgres://` in the open while a pasted value still stops the build. |
| `backup.sh` | dumps schemas and uploads to the private Storage bucket, verifying parse, DDL, size and landed byte length. Used by `db-backup.yml`. |
| `transfer-cfb.sh` | genesis Job 2 — moves `cfb` between projects and gates on exact per-table row counts, 46 of 46. |
| `sql/spot-checks.sql` | three known football facts, asserted. Raises on failure. |

All of these take their credentials from the environment and never write one to disk or to
stdout — connection strings are masked before they are printed.

## Restoring a backup

Small dumps land as a single `.dump` object. Anything above the project's global upload
ceiling lands as a `*.parts/` folder holding `part.0000`, `part.0001`, … and a
`manifest.json` with the byte count, part count and the sha256 of the whole dump.

```bash
# download every part, then
cat part.* > cfb.dump
sha256sum cfb.dump          # compare against manifest.json
pg_restore --dbname="$DATABASE_URL" --no-owner --no-privileges --jobs=4 cfb.dump
```

`split` writes fixed-size pieces in lexical order, so `cat part.*` reassembles the exact
bytes. Use the PostgreSQL 17 client — `pg_restore` 16 cannot read a 17.6 server's dump.

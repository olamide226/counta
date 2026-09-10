# SQL tests

Not migrations. Nothing in this directory is applied by `supabase db push` or
`supabase db reset` — `db.migrations.schema_paths` is empty and these files are
outside `supabase/migrations`. **Never run them against a hosted project:** they
create fixtures, install `dblink`, and delete what they created.

They exist because some of what `counta.redeem_voucher` guarantees is about
concurrency, and a single-threaded fake cannot tear a transaction apart. The
Deno suite (`make supabase-test`) covers every decision the endpoint makes on
top of the function; these cover the decisions the function makes when two
transactions arrive at once.

## Against the local Supabase stack

```bash
make supabase-start
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
  -v ON_ERROR_STOP=1 -f supabase/tests/redeem_voucher_race.sql
```

## Against a throwaway container

A bare Postgres has none of the Supabase furniture the migrations reference —
the `auth.users` table and the three PostgREST roles — so `bootstrap_local.sql`
stands those up first. It is for a container you are about to throw away and
nothing else.

```bash
docker run -d --name counta-pg -e POSTGRES_PASSWORD=postgres \
  -p 55432:5432 postgres:17-alpine
export PG="postgresql://postgres:postgres@127.0.0.1:55432/postgres"
psql "$PG" -v ON_ERROR_STOP=1 -f supabase/tests/bootstrap_local.sql
psql "$PG" -v ON_ERROR_STOP=1 -f supabase/migrations/20260907120000_voice_blocks.sql
psql "$PG" -v ON_ERROR_STOP=1 -f supabase/migrations/20260910092000_voucher_credited_at.sql
psql "$PG" -v ON_ERROR_STOP=1 -f supabase/migrations/20260910093000_redeem_voucher.sql
psql "$PG" -v ON_ERROR_STOP=1 -f supabase/tests/redeem_voucher_race.sql
docker rm -f counta-pg
```

Each test raises an exception on failure, so `ON_ERROR_STOP=1` makes a failing
run a non-zero exit.

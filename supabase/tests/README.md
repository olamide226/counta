# SQL tests

Not migrations. Nothing in this directory is applied by `supabase db push` or
`supabase db reset` — `db.migrations.schema_paths` is empty and these files are
outside `supabase/migrations`. **Never run them against a hosted project:** they
create fixtures, install `dblink`, and delete what they created. `run.sh`
refuses a URL that looks like one, but that is a guard, not a permission.

They exist because the decisions they cover live in SQL. The Deno suite
(`make supabase-test`) drives `MemoryVoucherStore`, an in-memory stand-in for
`counta.redeem_voucher`, and a fake cannot answer for a rule it only
re-implements: eight of `redeem_test.ts`'s tests used to assert the fake's copy
of the guess budget, the case folding, disabled-versus-unknown, the expiry, the
cap and the retry-after arithmetic, and would have stayed green through any
change to the function itself. Those decisions are tested here instead, against
a real database. What is left in `redeem_test.ts` is what the endpoint decides
on top of them: the HTTP shape, the wording of the refusals, and whether to pay.

- `redeem_voucher_decisions.sql` — every outcome the function can return, the
  attempt accounting behind the guess budget, and the slot/row invariant.
- `redeem_voucher_race.sql` — what it does when two transactions arrive at
  once, which a single-threaded fake can never show. `dblink` holds one
  transaction open while a second runs into it, so the race is deterministic
  rather than a matter of timing.

Both are re-runnable and leave nothing behind.

## Running them

```bash
make supabase-start           # the local stack, with the migrations applied
supabase/tests/run.sh         # every *.sql in this directory
```

`run.sh` takes an optional Postgres URL (or reads `SUPABASE_DB_URL`) and
defaults to the local stack at `127.0.0.1:54322`. Each test raises an exception
on failure and the runner exits non-zero.

**There is no Make target for this yet.** Add one next to `supabase-test`:

```make
# Run the SQL tests against the local stack (make supabase-start first).
supabase-test-sql:
	@bash supabase/tests/run.sh
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
for m in supabase/migrations/*.sql; do
  psql "$PG" -v ON_ERROR_STOP=1 -f "$m"
done
supabase/tests/run.sh "$PG"
docker rm -f counta-pg
```

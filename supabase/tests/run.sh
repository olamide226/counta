#!/usr/bin/env bash
#
# Runs every SQL test in this directory against a local Postgres.
#
# The Deno suite (`make supabase-test`) covers what the /redeem endpoint
# decides on top of counta.redeem_voucher; these cover what the function itself
# decides, against a real database, because a decision that lives in SQL cannot
# be tested against a re-implementation of it in TypeScript.
#
# Usage:
#   supabase/tests/run.sh [postgres-url]
#
# Defaults to the local Supabase stack (`make supabase-start`). For a throwaway
# container, apply bootstrap_local.sql and the migrations first — see README.md.
#
# Never point this at a hosted project: these files write fixtures, install
# dblink and delete what they created.
set -euo pipefail

DB_URL="${1:-${SUPABASE_DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}}"

case "$DB_URL" in
  *supabase.co*|*supabase.com*|*pooler.supabase*)
    echo "refusing to run SQL tests against what looks like a hosted project" >&2
    exit 1
    ;;
esac

cd "$(dirname "$0")"

status=0
for file in *.sql; do
  # Fixtures for a throwaway container, not a test.
  [ "$file" = "bootstrap_local.sql" ] && continue
  echo "--- $file"
  # Each test raises an exception on failure, so ON_ERROR_STOP is what makes a
  # failing run a failing exit code.
  if ! psql "$DB_URL" -v ON_ERROR_STOP=1 -q -f "$file"; then
    status=1
  fi
done

if [ "$status" -ne 0 ]; then
  echo "SQL tests failed" >&2
fi
exit "$status"

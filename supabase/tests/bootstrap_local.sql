-- Minimal stand-ins for the Supabase furniture the migrations reference, so
-- they can be applied to a throwaway `postgres:17-alpine` container.
--
-- NOT a migration and never to be run against a hosted project: a real
-- Supabase database already has all of this, and GoTrue owns `auth.users`.
-- See supabase/tests/README.md.

create schema if not exists auth;

-- Only the column the foreign keys name. GoTrue's real table has forty more.
create table if not exists auth.users (
  id uuid primary key default gen_random_uuid()
);

-- The three PostgREST roles the grants name.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
end;
$$;

-- The RLS policies in the first migration call these.
create or replace function auth.uid() returns uuid
  language sql stable as $$ select null::uuid $$;
create or replace function auth.role() returns text
  language sql stable as $$ select null::text $$;

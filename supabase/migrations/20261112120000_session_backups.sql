-- Saved sessions, backed up for signed-in accounts.
--
-- The app writes these rows itself, through PostgREST with the user's own
-- JWT, so RLS is the whole access story: a user reads and writes only rows
-- whose user_id is theirs. The phone stays the source of truth; this table is
-- what lets a second phone (or a reinstall) get the history back.
--
-- One row per saved session, keyed by the session's own id. Sessions are never
-- edited after saving, so there is nothing to merge: a row is either the
-- session or a deletion marker. The marker (data null, deleted_at set) is
-- kept so another phone that still has the session deletes it too, instead of
-- uploading it again.
create table if not exists counta.sessions (
  user_id    uuid not null default auth.uid()
               references auth.users (id) on delete cascade,
  id         text not null,
  data       jsonb,
  deleted_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (user_id, id),
  -- A session is a few hundred bytes; this only stops a misbehaving client
  -- from using the table as free storage.
  constraint sessions_data_size check (pg_column_size(data) < 65536),
  constraint sessions_id_size check (char_length(id) <= 64),
  constraint sessions_row_shape check ((data is null) = (deleted_at is not null))
);

alter table counta.sessions enable row level security;

drop policy if exists "own sessions readable" on counta.sessions;
create policy "own sessions readable" on counta.sessions
  for select to authenticated using (user_id = (select auth.uid()));

drop policy if exists "own sessions insertable" on counta.sessions;
create policy "own sessions insertable" on counta.sessions
  for insert to authenticated with check (user_id = (select auth.uid()));

drop policy if exists "own sessions updatable" on counta.sessions;
create policy "own sessions updatable" on counta.sessions
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- No delete grant: a deletion is an update to a marker, so other phones
-- learn of it. Rows go when the account does (the cascade above).
grant select, insert, update on counta.sessions to authenticated;
grant select, insert, update, delete on counta.sessions to service_role;

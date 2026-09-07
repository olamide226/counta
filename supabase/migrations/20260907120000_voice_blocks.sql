-- Voice phrase counting: block ledger, trial grants, remote matcher config.
-- See specs/voice-phrase-counting/design.md, "Supabase schema".
--
-- Re-runnable: every object is guarded, so a migration that failed halfway can
-- be applied again without hand-editing.

create table if not exists public.voice_blocks (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users on delete cascade,
  session_id     uuid not null,
  credits        int  not null,
  granted_at     timestamptz not null default now(),
  expires_at     timestamptz not null,
  reconciled     boolean not null default false,
  streamed_secs  int,
  detections     int
);

-- Rate-limit lookup: grants for one user inside a time window.
create index if not exists voice_blocks_user_granted_idx
  on public.voice_blocks (user_id, granted_at desc);

-- One live block per user (req 3.8), enforced by the database rather than by
-- the Edge Function's read-then-write, which two concurrent requests can both
-- pass. The design sketches `where expires_at > now()`; Postgres rejects that
-- because now() is not IMMUTABLE, but `not reconciled` is immutable and is the
-- predicate that actually matters: the function reconciles a block when it is
-- released, superseded by a renewal, or found expired, so the unreconciled set
-- is exactly the set that must stay unique.
drop index if exists public.voice_blocks_user_expires_idx;
create unique index if not exists voice_blocks_user_live_uniq
  on public.voice_blocks (user_id) where not reconciled;

alter table public.voice_blocks enable row level security;

drop policy if exists "own blocks readable" on public.voice_blocks;
create policy "own blocks readable" on public.voice_blocks
  for select using ((select auth.uid()) = user_id);
-- No client insert or update policy: writes come from the Edge Function using
-- the service role key only.

create table if not exists public.trial_grants (
  rc_app_user_id text primary key,
  credits        int not null,
  granted_at     timestamptz not null default now()
);

alter table public.trial_grants enable row level security;
-- No client policies at all: the one-time trial grant is written by the Edge
-- Function with the service role, and the primary key makes it idempotent.

create table if not exists public.matcher_config (
  id          int primary key default 1,
  config      jsonb not null,
  updated_at  timestamptz not null default now(),
  constraint singleton check (id = 1)
);

alter table public.matcher_config enable row level security;

drop policy if exists "config readable by all authed" on public.matcher_config;
create policy "config readable by all authed" on public.matcher_config
  for select using ((select auth.role()) = 'authenticated');

-- Deliberately unseeded. An absent row already means "use the compiled
-- MatcherConfig defaults" (lib/domain/counting/phrase_matcher.dart), and the
-- reader is task 14; a hand-copied duplicate of those defaults here would only
-- be a second source of truth to drift.

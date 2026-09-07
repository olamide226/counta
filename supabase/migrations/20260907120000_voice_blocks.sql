-- Voice phrase counting: block ledger, trial grants, remote matcher config.
-- See specs/voice-phrase-counting/design.md, "Supabase schema".

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

create index if not exists voice_blocks_user_granted_idx
  on public.voice_blocks (user_id, granted_at desc);

-- The design sketches `create index ... where expires_at > now()`; Postgres
-- rejects that because now() is not IMMUTABLE. A plain composite index serves
-- the same in-flight lookup (user_id = ? and expires_at > now()).
create index if not exists voice_blocks_user_expires_idx
  on public.voice_blocks (user_id, expires_at desc);

alter table public.voice_blocks enable row level security;

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

create policy "config readable by all authed" on public.matcher_config
  for select using ((select auth.role()) = 'authenticated');

-- Seed the singleton with the compiled MatcherConfig defaults
-- (lib/domain/counting/phrase_matcher.dart, lib/domain/counting/phrase_normaliser.dart)
-- so a fresh project matches the app's built-in behaviour until tuned.
insert into public.matcher_config (id, config)
values (
  1,
  '{
    "threshold": 0.80,
    "anchoredThreshold": 0.65,
    "refractoryMultiplier": 0,
    "refractoryFloorMs": 0,
    "windowSlack": 1.5,
    "homophones": {
      "won": "one",
      "too": "two",
      "to": "two",
      "for": "four"
    },
    "contractions": {
      "i''m": "i am",
      "im": "i am",
      "don''t": "do not",
      "dont": "do not",
      "can''t": "cannot",
      "cant": "cannot",
      "it''s": "it is",
      "its": "it is",
      "you''re": "you are",
      "youre": "you are",
      "we''re": "we are",
      "were": "we are",
      "they''re": "they are",
      "theyre": "they are"
    }
  }'::jsonb
)
on conflict (id) do nothing;

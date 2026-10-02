-- When the user asked to stop, as the server saw it.
--
-- A block is paid for up front, and stopping early gives the unused whole
-- minutes back. How many are unused depends on how long the block ran, and
-- that has to be the same answer on every attempt: a release whose refund
-- failed is retried, the refund is keyed on the block id, and a retry that
-- computed a different amount under the same key is not something to learn
-- the ledger's opinion of with a user's money.
--
-- So the first release attempt stamps this column and every later attempt
-- reads it back. It is the server's clock, never the client's: the client's
-- own `streamed_secs` is recorded for reconciliation and trusted for nothing.
alter table counta.voice_blocks
  add column if not exists released_at timestamptz;

comment on column counta.voice_blocks.released_at is
  'Server time of the first release attempt. Fixes the refund amount across retries. Null for a block that was superseded by a renewal or expired unreleased.';

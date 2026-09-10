-- Records that a redemption's credits actually reached the ledger.
--
-- Without it, "a voucher pays out once" rested entirely on RevenueCat keeping
-- the `Idempotency-Key` for the redemption's grant. Those keys expire on a
-- bounded window, and after that a valid, already-redeemed code credited again
-- every time it was submitted — with nothing counting the repeats, because the
-- success path records no rate-limit attempt. The endpoint has to be able to
-- ask "did this redemption already pay?" without asking the ledger, and this
-- is where the answer lives.
--
-- Nullable, and null on every row that existed before this migration: a
-- redemption whose payout is unknown is re-issued once, which is the same
-- keyed grant the endpoint would have sent anyway. That is the safe direction
-- — the ledger deduplicates a re-issue, while assuming "already paid" would
-- silently swallow a redemption whose credits never landed.
--
-- Timestamped ahead of *_redeem_voucher.sql because that function reads this
-- column. Neither migration has been applied anywhere yet.
--
-- Additive and confined to `counta`, like the migrations either side of it.

alter table counta.voucher_redemptions
  add column if not exists credited_at timestamptz;

comment on column counta.voucher_redemptions.credited_at is
  'When BalanceProvider.grant for this redemption succeeded. Null means the '
  'payout is unconfirmed and the next redemption of this code by this user '
  're-issues the same keyed grant (req 12.5).';

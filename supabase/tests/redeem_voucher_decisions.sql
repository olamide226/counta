-- Every decision counta.redeem_voucher makes, against the real function.
--
-- NOT a migration. Local databases only — it writes fixtures and deletes them
-- again. See supabase/tests/README.md.
--
-- These used to be Deno tests, and they passed against MemoryVoucherStore's
-- ninety-line re-implementation of this function: the guess budget, the case
-- folding, disabled-versus-unknown, the expiry, the cap and the retry-after
-- arithmetic all had a second copy in testing/fakes.ts, and it was that copy
-- being asserted. A fake that agrees with the SQL today stays green when the
-- SQL changes tomorrow, which is the one thing a test must not do. What is
-- left in redeem_test.ts is what the *endpoint* decides on top of these
-- answers: the HTTP shape, the wording of the refusals, and whether to pay.
--
-- The whole file is one transaction, so a failed assertion rolls the fixtures
-- back; the successful path deletes them at the end.

-- Assertions, session-local: nothing outside `counta` and `auth.users` is
-- named permanently, here or in the migrations.
create or replace function pg_temp.eq(p_actual text, p_expected text, p_what text)
returns void language plpgsql as $fn$
begin
  if p_actual is distinct from p_expected then
    raise exception '%: expected %, got %', p_what, p_expected, p_actual;
  end if;
end;
$fn$;

do $$
declare
  v_user     uuid;
  v_other    uuid;
  v_third    uuid;
  v_live     uuid;
  v_disabled uuid;
  v_expired  uuid;
  v_forever  uuid;
  v_capped   uuid;
  v_guessed  uuid;
  r          jsonb;
  unknown    jsonb;
  n          int;
  before     int;
begin
  insert into auth.users default values returning id into v_user;
  insert into auth.users default values returning id into v_other;
  insert into auth.users default values returning id into v_third;

  insert into counta.vouchers (code, credits, max_redemptions, note)
       values ('DECIDE1', 50, 5, 'supabase/tests/redeem_voucher_decisions.sql')
    returning id into v_live;
  insert into counta.vouchers (code, credits, max_redemptions, enabled, note)
       values ('RETIRED1', 50, 5, false, 'supabase/tests/redeem_voucher_decisions.sql')
    returning id into v_disabled;
  insert into counta.vouchers (code, credits, max_redemptions, expires_at, note)
       values ('EXPIRED1', 50, 5, now() - interval '1 second', 'supabase/tests/redeem_voucher_decisions.sql')
    returning id into v_expired;
  insert into counta.vouchers (code, credits, max_redemptions, expires_at, note)
       values ('FOREVER1', 50, 5, null, 'supabase/tests/redeem_voucher_decisions.sql')
    returning id into v_forever;
  insert into counta.vouchers (code, credits, max_redemptions, note)
       values ('CAPPED1', 50, 2, 'supabase/tests/redeem_voucher_decisions.sql')
    returning id into v_capped;

  -- -------------------------------------------------------------------------
  -- The lookup folds case (req 12.4's index is on upper(code)): the codes are
  -- typed by hand off a card or an email. Trimming is the endpoint's job, not
  -- this function's.
  r := counta.redeem_voucher('decide1', v_user, 60, 100);
  perform pg_temp.eq(r->>'outcome', 'redeemed', 'a lowercase code');
  perform pg_temp.eq(r->>'voucher_id', v_live::text, 'the voucher it matched');
  perform pg_temp.eq(r->>'credits', '50', 'the credits it pays');
  -- Written a moment ago by this transaction, so nothing has paid for it yet.
  perform pg_temp.eq(r->>'credited', 'false', 'a fresh redemption is unpaid');

  -- A repeat hands back the same redemption rather than a second one (12.5),
  -- and claims no further slot.
  r := counta.redeem_voucher('DECIDE1', v_user, 60, 100);
  perform pg_temp.eq(r->>'outcome', 'already_redeemed', 'the same user again');
  perform pg_temp.eq(
    r->>'redemption_id',
    (select id::text from counta.voucher_redemptions
      where voucher_id = v_live and user_id = v_user),
    'the redemption it reports');
  select redeemed_count into n from counta.vouchers where id = v_live;
  perform pg_temp.eq(n::text, '1', 'a repeat claims no second slot');

  -- `credited` is read from credited_at, which is what the endpoint sets after
  -- the ledger call lands. Null means the payout is unconfirmed and the same
  -- keyed grant is re-issued; set means nothing more is paid.
  update counta.voucher_redemptions set credited_at = now()
   where voucher_id = v_live and user_id = v_user;
  r := counta.redeem_voucher('DECIDE1', v_user, 60, 100);
  perform pg_temp.eq(r->>'credited', 'true', 'a confirmed payout');

  -- Neither of those is a failed attempt, so neither eats the guess budget.
  select count(*) into n from counta.voucher_attempts where user_id = v_user;
  perform pg_temp.eq(n::text, '0', 'a redemption records no attempt');

  -- -------------------------------------------------------------------------
  -- An unknown code and a disabled one are the same answer with no way to tell
  -- them apart (12.6): distinguishing them would turn the endpoint into an
  -- oracle for discovering which campaigns are live.
  unknown := counta.redeem_voucher('NOSUCHCODE', v_other, 60, 100);
  r := counta.redeem_voucher('RETIRED1', v_other, 60, 100);
  perform pg_temp.eq(r::text, unknown::text, 'a disabled code');
  perform pg_temp.eq(unknown->>'outcome', 'not_found', 'an unknown code');
  -- Both cost a guess.
  select count(*) into n from counta.voucher_attempts where user_id = v_other;
  perform pg_temp.eq(n::text, '2', 'both refusals are counted');

  -- But a user who has already redeemed a code gets their redemption back even
  -- after the operator retires the campaign, so a payout whose ledger call died
  -- mid-flight can still be completed. It leaks nothing: you only learn the
  -- code exists if you have already redeemed it.
  update counta.vouchers set enabled = false where id = v_live;
  r := counta.redeem_voucher('DECIDE1', v_user, 60, 100);
  perform pg_temp.eq(r->>'outcome', 'already_redeemed', 'a retired code already redeemed');
  update counta.vouchers set enabled = true where id = v_live;

  -- -------------------------------------------------------------------------
  -- Expiry is decided on server time, never the client's (12.9), and gets its
  -- own answer (12.7): it reaches a user holding a real code.
  before := (select count(*) from counta.voucher_attempts where user_id = v_third);
  r := counta.redeem_voucher('EXPIRED1', v_third, 60, 100);
  perform pg_temp.eq(r->>'outcome', 'expired', 'a code past its expiry');
  select count(*) into n from counta.voucher_attempts where user_id = v_third;
  perform pg_temp.eq((n - before)::text, '1', 'an expiry costs a guess');

  -- A null expiry never expires.
  r := counta.redeem_voucher('FOREVER1', v_third, 60, 100);
  perform pg_temp.eq(r->>'outcome', 'redeemed', 'a code with no expiry');

  -- -------------------------------------------------------------------------
  -- The campaign cap, claimed one slot at a time.
  perform pg_temp.eq(
    (counta.redeem_voucher('CAPPED1', v_user, 60, 100))->>'outcome',
    'redeemed', 'the first of two slots');
  perform pg_temp.eq(
    (counta.redeem_voucher('CAPPED1', v_other, 60, 100))->>'outcome',
    'redeemed', 'the last slot');
  before := (select count(*) from counta.voucher_attempts where user_id = v_third);
  r := counta.redeem_voucher('CAPPED1', v_third, 60, 100);
  perform pg_temp.eq(r->>'outcome', 'exhausted', 'a full campaign');
  select count(*) into n from counta.voucher_attempts where user_id = v_third;
  perform pg_temp.eq((n - before)::text, '1', 'an exhaustion costs a guess');

  select redeemed_count into n from counta.vouchers where id = v_capped;
  perform pg_temp.eq(n::text, '2', 'the cap was not exceeded');

  -- -------------------------------------------------------------------------
  -- The guess budget (12.8). now() is the transaction's start time and does
  -- not move inside this block, so backdating the attempts is what moves the
  -- window — and makes the retry-after exact rather than approximate.
  insert into auth.users default values returning id into v_guessed;
  insert into counta.voucher_attempts (user_id, attempted_at) values
    (v_guessed, now() - interval '5 minutes'),
    (v_guessed, now() - interval '2 minutes'),
    (v_guessed, now() - interval '1 minute');

  r := counta.redeem_voucher('DECIDE1', v_guessed, 60, 3);
  perform pg_temp.eq(r->>'outcome', 'too_many_attempts', 'a caller at the budget');
  perform pg_temp.eq(r->>'attempts', '3', 'the attempts in the window');
  -- Counted from the oldest attempt still in the window, not from now: five of
  -- the sixty minutes have already passed.
  perform pg_temp.eq(r->>'retry_after_seconds', '3300', 'the retry hint');

  -- A rate-limited request records nothing. Counting refusals of refusals
  -- would let the window renew itself for as long as the caller kept knocking,
  -- so the block could never lift.
  select count(*) into n from counta.voucher_attempts where user_id = v_guessed;
  perform pg_temp.eq(n::text, '3', 'a refused refusal is not an attempt');

  -- A real code is not redeemable while the block stands...
  perform pg_temp.eq(
    (counta.redeem_voucher('DECIDE1', v_guessed, 60, 3))->>'outcome',
    'too_many_attempts', 'a live code under the block');
  -- ...and only attempts inside the window count, so the block lifts.
  perform pg_temp.eq(
    (counta.redeem_voucher('DECIDE1', v_guessed, 3, 3))->>'outcome',
    'redeemed', 'the window sliding past the oldest attempts');

  -- -------------------------------------------------------------------------
  -- The invariant the whole function exists to hold: a slot claimed with no
  -- redemption behind it under-grants a campaign, and a redemption with no
  -- slot behind it lets the advertised cap be exceeded.
  select count(*) into n
    from counta.vouchers v
   where v.id in (v_live, v_disabled, v_expired, v_forever, v_capped)
     and v.redeemed_count <> (
       select count(*) from counta.voucher_redemptions r where r.voucher_id = v.id);
  perform pg_temp.eq(n::text, '0', 'slots and redemption rows agree');

  raise notice 'redeem_voucher decisions: ok';

  delete from counta.voucher_redemptions
   where voucher_id in (v_live, v_disabled, v_expired, v_forever, v_capped);
  delete from counta.voucher_attempts
   where user_id in (v_user, v_other, v_third, v_guessed);
  delete from counta.vouchers
   where id in (v_live, v_disabled, v_expired, v_forever, v_capped);
  delete from auth.users where id in (v_user, v_other, v_third, v_guessed);
end;
$$;

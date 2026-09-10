-- Voucher redemption as one transaction: counta.redeem_voucher.
--
-- See specs/voice-phrase-counting/design.md, "Edge Function contract". The
-- slot claim on counta.vouchers and the row in counta.voucher_redemptions are
-- two writes that must not come apart. A slot claimed with no redemption
-- behind it under-grants a campaign by one; a redemption with no slot behind
-- it lets the advertised cap be exceeded. When the two failure directions are
-- under-granting and over-granting credit, take the first — and better still,
-- make the pair atomic, which is what this function is for. It also collapses
-- the whole decision into a single round trip from the Edge Function.
--
-- Additive and confined to `counta`, like 20260907120000_voice_blocks.sql,
-- which is merged and must not be edited. Nothing outside `counta` is named.

create or replace function counta.redeem_voucher(p_code text, p_user_id uuid)
returns jsonb
language plpgsql
-- SECURITY INVOKER (the default): the only caller is the Edge Function's
-- service-role client, which already holds the DML grants and bypasses RLS.
-- A definer function would hand those privileges to whoever could execute it,
-- which is a larger blast radius for no benefit.
volatile
-- pg_catalog is implicitly first anyway; naming it (with pg_temp last) stops a
-- caller's search_path from resolving an unqualified name to something of
-- their own. Every table below is schema-qualified regardless.
set search_path = pg_catalog, pg_temp
as $$
declare
  v_voucher    counta.vouchers%rowtype;
  v_redemption counta.voucher_redemptions%rowtype;
  v_new_id     uuid;
begin
  -- Case-insensitive, through the unique index on upper(code): the codes are
  -- typed by hand off a card or an email.
  select * into v_voucher
    from counta.vouchers v
   where upper(v.code) = upper(p_code);

  if not found then
    return jsonb_build_object('outcome', 'not_found');
  end if;

  -- Before anything else, and deliberately before the `enabled` check: a user
  -- who already redeemed this code gets their redemption back even after the
  -- operator has retired the campaign, so a payout whose ledger call died
  -- mid-flight can still be completed by a retry (req 12.5). It leaks nothing
  -- — you only learn the code exists if you have already redeemed it.
  select * into v_redemption
    from counta.voucher_redemptions r
   where r.voucher_id = v_voucher.id
     and r.user_id = p_user_id;

  if found then
    return jsonb_build_object(
      'outcome', 'already_redeemed',
      'voucher_id', v_voucher.id,
      'redemption_id', v_redemption.id,
      'credits', v_redemption.credits);
  end if;

  -- A disabled code answers exactly as an unknown one does, with no way to
  -- tell them apart (req 12.6). Distinguishing them would turn the endpoint
  -- into an oracle for discovering which campaigns are live.
  if not v_voucher.enabled then
    return jsonb_build_object('outcome', 'not_found');
  end if;

  -- Server time, never the client's (req 12.9). A null expiry never expires.
  if v_voucher.expires_at is not null and v_voucher.expires_at <= now() then
    return jsonb_build_object('outcome', 'expired');
  end if;

  -- Claim the slot first. The predicate takes the row lock and refuses
  -- cleanly when the campaign is full, so two concurrent redemptions of the
  -- last slot cannot both pass; `vouchers_within_cap` is the backstop for a
  -- writer that forgets it.
  update counta.vouchers v
     set redeemed_count = v.redeemed_count + 1
   where v.id = v_voucher.id
     and v.redeemed_count < v.max_redemptions;

  if not found then
    -- Not necessarily exhausted *for this caller*. Two requests from one user
    -- racing the last slot — a double tap, or a client retry — both read no
    -- redemption above, because the loser's lookup ran on a snapshot taken
    -- before the winner committed. The update then blocks on the winner's row
    -- lock and, once it is released, re-evaluates against the new version and
    -- finds the campaign full. Answering `exhausted` there tells a user their
    -- code is used up for a code they have just redeemed, records a
    -- rate-limit attempt against them for it, and — worse — makes the
    -- re-issue path unreachable, so a winner whose ledger call failed can
    -- never heal.
    --
    -- Re-read instead. This is a new statement, so it takes a new snapshot,
    -- and the update it followed waited on the winner's lock: whatever the
    -- winner wrote is visible now.
    select * into v_redemption
      from counta.voucher_redemptions r
     where r.voucher_id = v_voucher.id
       and r.user_id = p_user_id;

    if found then
      return jsonb_build_object(
        'outcome', 'already_redeemed',
        'voucher_id', v_voucher.id,
        'redemption_id', v_redemption.id,
        'credits', v_redemption.credits);
    end if;

    return jsonb_build_object('outcome', 'exhausted');
  end if;

  insert into counta.voucher_redemptions (voucher_id, user_id, credits)
       values (v_voucher.id, p_user_id, v_voucher.credits)
  on conflict (voucher_id, user_id) do nothing
    returning id into v_new_id;

  if v_new_id is null then
    -- Lost a race with this same user's other in-flight redemption. Give the
    -- slot back — it was never used — and report the row that won, so the
    -- caller re-issues that redemption's keyed grant rather than a second one.
    update counta.vouchers v
       set redeemed_count = v.redeemed_count - 1
     where v.id = v_voucher.id;

    select * into v_redemption
      from counta.voucher_redemptions r
     where r.voucher_id = v_voucher.id
       and r.user_id = p_user_id;

    return jsonb_build_object(
      'outcome', 'already_redeemed',
      'voucher_id', v_voucher.id,
      'redemption_id', v_redemption.id,
      'credits', v_redemption.credits);
  end if;

  return jsonb_build_object(
    'outcome', 'redeemed',
    'voucher_id', v_voucher.id,
    'redemption_id', v_new_id,
    'credits', v_voucher.credits);
end;
$$;

comment on function counta.redeem_voucher(text, uuid) is
  'Redeems a voucher code for a user in one transaction: lookup by upper(code), '
  'cap claim and redemption row. Returns {outcome, voucher_id, redemption_id, '
  'credits}; outcome is redeemed | already_redeemed | not_found | expired | '
  'exhausted, and not_found covers both an unknown and a disabled code.';

-- Only the Edge Function's service role may call it. `authenticated` could not
-- get past RLS anyway, but a function that grants credit should not be on the
-- Data API surface for any client role at all (req 12.10).
revoke all on function counta.redeem_voucher(text, uuid) from public;
grant execute on function counta.redeem_voucher(text, uuid) to service_role;

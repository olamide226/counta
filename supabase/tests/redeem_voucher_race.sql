-- counta.redeem_voucher under concurrency.
--
-- NOT a migration. Local databases only — it installs dblink, writes fixtures
-- and deletes them again. See supabase/tests/README.md.
--
-- The Deno suite covers every decision the /redeem endpoint makes on top of
-- this function, but it drives an in-memory double: a single-threaded fake
-- cannot tear a transaction apart, so the one thing it can never show is what
-- happens when two requests arrive at once. dblink is used to hold one
-- transaction open while a second one runs into it, which makes the race
-- deterministic rather than a matter of timing.

create extension if not exists dblink;

do $$
declare
  conn      text := 'dbname=' || current_database() || ' user=' || current_user;
  v_user    uuid;
  v_other   uuid;
  v_voucher uuid;
  winner    jsonb;
  loser     jsonb;
  stranger  jsonb;
  slots     int;
  rows_out  int;
begin
  insert into auth.users default values returning id into v_user;
  insert into auth.users default values returning id into v_other;
  -- One slot, so the loser's slot claim is the statement that has to wait.
  insert into counta.vouchers (code, credits, max_redemptions, note)
       values ('RACE1', 50, 1, 'supabase/tests/redeem_voucher_race.sql')
    returning id into v_voucher;

  -- dblink opens real, separate sessions, so the fixtures have to be visible
  -- to them: without this commit the two connections below see no such code
  -- and the whole test degenerates into two `not_found`s.
  commit;

  perform dblink_connect('winner', conn);
  perform dblink_connect('loser', conn);

  begin
    -- The winner claims the last slot and writes its redemption, and then
    -- sits on both, uncommitted.
    perform dblink_exec('winner', 'begin');
    select result into winner from dblink(
      'winner',
      format('select counta.redeem_voucher(%L, %L)', 'RACE1', v_user)
    ) as t(result jsonb);
    if winner->>'outcome' <> 'redeemed' then
      raise exception 'setup: the winner expected redeemed, got %', winner;
    end if;

    -- The same user again — a double tap, or a client retry. Its redemption
    -- lookup runs on a snapshot taken before the winner committed, so it sees
    -- no redemption and falls through to the slot claim, where it blocks.
    perform dblink_send_query(
      'loser',
      format('select counta.redeem_voucher(%L, %L)', 'RACE1', v_user)
    );
    perform pg_sleep(0.5);
    if dblink_is_busy('loser') <> 1 then
      raise exception
        'the second request did not block on the first: this is not the race';
    end if;

    perform dblink_exec('winner', 'commit');

    select result into loser
      from dblink_get_result('loser') as t(result jsonb);
    -- libpq hands results back one at a time and the connection is not usable
    -- again until the empty terminator has been read.
    perform * from dblink_get_result('loser') as t(ignored jsonb);

    -- The regression. Before the re-read, the blocked claim re-evaluated
    -- against the committed row, found the campaign full and answered
    -- `exhausted` — telling a user their code was used up for a code they had
    -- just redeemed, recording a rate-limit attempt against them for it, and
    -- leaving the re-issue path unreachable, so a winner whose ledger call
    -- had failed could never heal.
    if loser->>'outcome' <> 'already_redeemed' then
      raise exception
        'same-user race answered %, expected already_redeemed', loser;
    end if;
    if loser->>'redemption_id' <> (winner->>'redemption_id') then
      raise exception
        'the loser reported redemption %, the winner wrote %',
        loser->>'redemption_id', winner->>'redemption_id';
    end if;

    -- And the cap still holds: one slot claimed, one row, and they agree.
    select redeemed_count into slots
      from counta.vouchers where id = v_voucher;
    select count(*) into rows_out
      from counta.voucher_redemptions where voucher_id = v_voucher;
    if slots <> 1 or rows_out <> 1 then
      raise exception
        'slot/row disagreement after the race: % slots, % rows', slots, rows_out;
    end if;

    -- A genuinely full campaign still says so to somebody who has not
    -- redeemed it. The re-read must not turn every exhaustion into a
    -- redemption the caller never had.
    select counta.redeem_voucher('RACE1', v_other) into stranger;
    if stranger->>'outcome' <> 'exhausted' then
      raise exception
        'a full campaign answered % for a new user, expected exhausted',
        stranger;
    end if;

    raise notice 'redeem_voucher race: ok';
  exception
    when others then
      perform dblink_disconnect('winner');
      perform dblink_disconnect('loser');
      raise;
  end;

  perform dblink_disconnect('winner');
  perform dblink_disconnect('loser');

  delete from counta.voucher_redemptions where voucher_id = v_voucher;
  delete from counta.vouchers where id = v_voucher;
  delete from auth.users where id in (v_user, v_other);
end;
$$;

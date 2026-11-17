-- =====================================================================
-- Tests for the timed drills migration (2026-11-17-timed-drills.sql)
--
-- Run AFTER the migration, as one go, in the Supabase SQL Editor.
--
-- What it does, in plain language:
--   - Creates two pretend squads (A and B), a player in each, and three
--     pretend coaches: Coach A (squad A), Lead A (lead of squad A) and
--     Coach B (squad B).
--   - Gives each squad a pretend timed drill with the cut-offs
--     5 = 1:00 or under, 4 = up to 1:06, 3 = up to 1:12, 2 = up to 1:20.
--   - Signs in as each pretend coach in turn and checks what they can
--     and can't see or do, including the new time_seconds column.
--   - Then deliberately stops with a message, which UNDOES EVERYTHING.
--     None of the pretend data is kept.
--
-- How to read the result:
--   - "ALL 12 TIMED DRILL TESTS PASSED" (shown as an error, on purpose)
--     = all good.
--   - "TEST n FAILED: ..." = something isn't working as intended.
--     Don't merge the app change; send me the message.
--   - Any other error = something about the test setup didn't fit your
--     database. Send me the message.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- Pretend data (created with full rights, before signing in as anyone)
-- ---------------------------------------------------------------------
insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-0000000000c1', 'test-coach-a@example.invalid'),
  ('00000000-0000-4000-8000-0000000000c2', 'test-lead-a@example.invalid'),
  ('00000000-0000-4000-8000-0000000000c3', 'test-coach-b@example.invalid');

insert into public.profiles (id, email) values
  ('00000000-0000-4000-8000-0000000000c1', 'test-coach-a@example.invalid'),
  ('00000000-0000-4000-8000-0000000000c2', 'test-lead-a@example.invalid'),
  ('00000000-0000-4000-8000-0000000000c3', 'test-coach-b@example.invalid')
on conflict (id) do nothing;

insert into public.squads (id, name) values
  ('00000000-0000-4000-8000-0000000000a1', 'TEST Squad A'),
  ('00000000-0000-4000-8000-0000000000b1', 'TEST Squad B');

insert into public.attributes (id, squad_id, name, category, sort_order) values
  ('00000000-0000-4000-8000-0000000000a2', '00000000-0000-4000-8000-0000000000a1', 'TEST Sprint', 'physical', 1),
  ('00000000-0000-4000-8000-0000000000b2', '00000000-0000-4000-8000-0000000000b1', 'TEST Sprint', 'physical', 1);

insert into public.players (id, squad_id, name, age) values
  ('00000000-0000-4000-8000-0000000000a3', '00000000-0000-4000-8000-0000000000a1', 'TEST Player A', 15),
  ('00000000-0000-4000-8000-0000000000b3', '00000000-0000-4000-8000-0000000000b1', 'TEST Player B', 15);

insert into public.coach_squads (coach_id, squad_id, is_lead) values
  ('00000000-0000-4000-8000-0000000000c1', '00000000-0000-4000-8000-0000000000a1', false),
  ('00000000-0000-4000-8000-0000000000c2', '00000000-0000-4000-8000-0000000000a1', true),
  ('00000000-0000-4000-8000-0000000000c3', '00000000-0000-4000-8000-0000000000b1', false);

-- A timed drill per squad, plus one attempt drill in squad A.
insert into public.drills (id, name, attribute_id, config) values
  ('00000000-0000-4000-8000-0000000000a4', 'TEST Timed A', '00000000-0000-4000-8000-0000000000a2',
   '{"measure": "time", "tags": ["Wet pitch"], "time_cutoffs": [80, 72, 66, 60]}'),
  ('00000000-0000-4000-8000-0000000000b4', 'TEST Timed B', '00000000-0000-4000-8000-0000000000b2',
   '{"measure": "time", "tags": [], "time_cutoffs": [80, 72, 66, 60]}'),
  ('00000000-0000-4000-8000-0000000000a6', 'TEST Attempts A', '00000000-0000-4000-8000-0000000000a2',
   '{"attempts": 2, "results": [{"label": "Hit", "points": 1}, {"label": "Miss", "points": 0}],
     "retake_enabled": false, "retake_label": "Retake", "tags": [], "cutoffs": [40, 60, 75, 90]}');

-- One existing timed entry in squad B (1:10).
insert into public.drill_entries (id, drill_id, player_id, time_seconds, recorded_by) values
  ('00000000-0000-4000-8000-0000000000b5', '00000000-0000-4000-8000-0000000000b4',
   '00000000-0000-4000-8000-0000000000b3', 70, '00000000-0000-4000-8000-0000000000c3');

-- From here on, act as a signed-in coach (RLS applies).
set local role authenticated;

-- =====================================================================
-- As COACH A (squad A, not a lead)
-- =====================================================================
select set_config('request.jwt.claims',
  '{"sub": "00000000-0000-4000-8000-0000000000c1", "role": "authenticated"}', true);

do $$
declare
  e record;
begin
  -- 1. Coach A saves a time of 1:06 (66 seconds) for their own player.
  --    The app's level (1) and total (99) are ignored: the database
  --    works out level 4 from the time, with no total and no attempts.
  insert into drill_entries (drill_id, player_id, time_seconds, total, level, tags) values
    ('00000000-0000-4000-8000-0000000000a4', '00000000-0000-4000-8000-0000000000a3', 66, 99, 1, '{Wet pitch}')
  returning * into e;

  if e.level <> 4 or e.total is not null or e.attempts <> '[]'::jsonb or e.time_seconds <> 66 then
    raise exception 'TEST 1 FAILED: expected level 4, no total, no attempts, time 66; got level %, total %, attempts %, time %.',
      e.level, e.total, e.attempts, e.time_seconds;
  end if;

  -- 2. Saving it added a matching score of 4 for the drill's attribute.
  if not exists (
    select 1 from scores
    where player_id = '00000000-0000-4000-8000-0000000000a3'
      and attribute_id = '00000000-0000-4000-8000-0000000000a2'
      and value = 4
      and scored_by = '00000000-0000-4000-8000-0000000000c1'
  ) then
    raise exception 'TEST 2 FAILED: no matching score of 4 was added.';
  end if;
end $$;

do $$
declare
  t numeric;
  want int;
  got int;
begin
  -- 3. Times right on and just past each cut-off land on the right level.
  --    "Up to 1:06" includes 1:06 itself.
  for t, want in
    select * from (values (60, 5), (61, 4), (72, 3), (73, 2), (80, 2), (81, 1), (59.5, 5)) v(t, want)
  loop
    insert into drill_entries (drill_id, player_id, time_seconds) values
      ('00000000-0000-4000-8000-0000000000a4', '00000000-0000-4000-8000-0000000000a3', t)
    returning level into got;
    if got <> want then
      raise exception 'TEST 3 FAILED: a time of % seconds gave level %, expected %.', t, got, want;
    end if;
  end loop;
end $$;

do $$
begin
  -- 4. Coach A can read the time on their own squad's entries...
  if not exists (
    select 1 from drill_entries
    where player_id = '00000000-0000-4000-8000-0000000000a3' and time_seconds = 66
  ) then
    raise exception 'TEST 4 FAILED: Coach A cannot see the time on their own squad''s entry.';
  end if;

  -- ...but not squad B's (the key test).
  if (select count(*) from drill_entries
      where id = '00000000-0000-4000-8000-0000000000b5') <> 0 then
    raise exception 'TEST 4 FAILED: Coach A can see squad B''s timed entry.';
  end if;
end $$;

do $$
begin
  -- 5. Coach A cannot save a time for squad B's player.
  begin
    insert into drill_entries (drill_id, player_id, time_seconds) values
      ('00000000-0000-4000-8000-0000000000b4', '00000000-0000-4000-8000-0000000000b3', 55);
    raise exception 'TEST 5 FAILED: Coach A saved a time for squad B.';
  exception
    when raise_exception then
      if sqlerrm like 'TEST 5 FAILED%' then raise; end if;
    when others then null;  -- blocked, as intended
  end;

  -- 6. A timed drill refuses an entry with no time, or a time of 0.
  begin
    insert into drill_entries (drill_id, player_id) values
      ('00000000-0000-4000-8000-0000000000a4', '00000000-0000-4000-8000-0000000000a3');
    raise exception 'TEST 6 FAILED: a timed drill accepted an entry with no time.';
  exception
    when raise_exception then
      if sqlerrm like 'TEST 6 FAILED%' then raise; end if;
  end;
  begin
    insert into drill_entries (drill_id, player_id, time_seconds) values
      ('00000000-0000-4000-8000-0000000000a4', '00000000-0000-4000-8000-0000000000a3', 0);
    raise exception 'TEST 6 FAILED: a timed drill accepted a time of 0.';
  exception
    when raise_exception then
      if sqlerrm like 'TEST 6 FAILED%' then raise; end if;
    when check_violation then null;  -- blocked, as intended
  end;
end $$;

do $$
declare
  e record;
begin
  -- 7. Attempt drills work as before, and ignore a time if one is sent.
  --    [1, 0] = 1 out of 2 = 50% → level 2.
  insert into drill_entries (drill_id, player_id, attempts, time_seconds) values
    ('00000000-0000-4000-8000-0000000000a6', '00000000-0000-4000-8000-0000000000a3', '[1, 0]', 30)
  returning * into e;
  if e.level <> 2 or e.total <> 1 or e.time_seconds is not null then
    raise exception 'TEST 7 FAILED: attempt drill gave level %, total %, time %.', e.level, e.total, e.time_seconds;
  end if;
end $$;

do $$
begin
  -- 8. Coach A (not a lead) cannot create a timed drill.
  begin
    insert into drills (name, attribute_id, config) values
      ('Sneaky timed drill', '00000000-0000-4000-8000-0000000000a2',
       '{"measure": "time", "tags": [], "time_cutoffs": [80, 72, 66, 60]}');
    raise exception 'TEST 8 FAILED: Coach A (not a lead) created a timed drill.';
  exception
    when raise_exception then
      if sqlerrm like 'TEST 8 FAILED%' then raise; end if;
    when others then null;  -- blocked, as intended
  end;
end $$;

-- =====================================================================
-- As LEAD A (lead of squad A)
-- =====================================================================
select set_config('request.jwt.claims',
  '{"sub": "00000000-0000-4000-8000-0000000000c2", "role": "authenticated"}', true);

do $$
declare
  d record;
begin
  -- 9. Lead A can create a timed drill for squad A.
  insert into drills (name, attribute_id, config) values
    ('Lead timed drill', '00000000-0000-4000-8000-0000000000a2',
     '{"measure": "time", "tags": [], "time_cutoffs": [300, 270, 240, 210]}')
  returning * into d;
  if d.squad_id <> '00000000-0000-4000-8000-0000000000a1' then
    raise exception 'TEST 9 FAILED: the new timed drill was not placed in squad A.';
  end if;

  -- 10. Cut-offs that get slower instead of faster are refused.
  begin
    insert into drills (name, attribute_id, config) values
      ('Backwards drill', '00000000-0000-4000-8000-0000000000a2',
       '{"measure": "time", "tags": [], "time_cutoffs": [60, 66, 72, 80]}');
    raise exception 'TEST 10 FAILED: cut-offs in the wrong order were accepted.';
  exception
    when raise_exception then
      if sqlerrm like 'TEST 10 FAILED%' then raise; end if;
    when check_violation then null;  -- blocked, as intended
  end;

  -- 11. A drill that has been run can't switch from Time to Attempts.
  begin
    update drills set config =
      '{"measure": "attempts", "attempts": 5, "results": [{"label": "Hit", "points": 1}],
        "retake_enabled": false, "retake_label": "Retake", "tags": [], "cutoffs": [40, 60, 75, 90]}'
    where id = '00000000-0000-4000-8000-0000000000a4';
    raise exception 'TEST 11 FAILED: a drill with entries was switched from Time to Attempts.';
  exception
    when raise_exception then
      if sqlerrm like 'TEST 11 FAILED%' then raise; end if;
      if sqlerrm not like '%switched between Attempts and Time%' then raise; end if;
  end;
end $$;

-- =====================================================================
-- As COACH B (squad B)
-- =====================================================================
select set_config('request.jwt.claims',
  '{"sub": "00000000-0000-4000-8000-0000000000c3", "role": "authenticated"}', true);

do $$
begin
  -- 12. Coach B sees their own timed entry (with its time and level 3),
  --     and none of squad A's.
  if not exists (
    select 1 from drill_entries
    where id = '00000000-0000-4000-8000-0000000000b5' and time_seconds = 70 and level = 3
  ) then
    raise exception 'TEST 12 FAILED: Coach B cannot see their own timed entry, or its level isn''t 3.';
  end if;
  if (select count(*) from drill_entries
      where player_id = '00000000-0000-4000-8000-0000000000a3') <> 0 then
    raise exception 'TEST 12 FAILED: Coach B can see squad A''s entries.';
  end if;
end $$;

-- =====================================================================
-- All passed: stop on purpose so everything above is undone.
-- =====================================================================
do $$
begin
  raise exception 'ALL 12 TIMED DRILL TESTS PASSED. (This is shown as an error on purpose: it undoes all the pretend test data, so nothing is kept.)';
end $$;

rollback;

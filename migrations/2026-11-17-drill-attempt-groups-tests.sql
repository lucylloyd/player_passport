-- =====================================================================
-- Tests for the attempt groups migration (2026-11-17-drill-attempt-groups.sql)
--
-- Run AFTER the migration, as one go, in the Supabase SQL Editor.
--
-- What it does, in plain language:
--   - Creates two pretend squads (A and B), a player in each, and three
--     pretend coaches: Coach A (squad A), Lead A (lead of squad A) and
--     Coach B (squad B).
--   - Gives each squad a pretend grouped drill: Left × 2 then Right × 3,
--     result buttons Hit (2 points) and Miss (0).
--   - Signs in as each pretend coach in turn and checks the group
--     subtotals, the combined level, and who can see what.
--   - Then deliberately stops with a message, which UNDOES EVERYTHING.
--     None of the pretend data is kept, and your real drills (including
--     the new "Movement into kicking" drill) aren't touched.
--
-- How to read the result:
--   - "ALL 10 ATTEMPT GROUP TESTS PASSED" (shown as an error, on purpose)
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
  ('00000000-0000-4000-8000-0000000000a2', '00000000-0000-4000-8000-0000000000a1', 'TEST Kicking', 'technical', 1),
  ('00000000-0000-4000-8000-0000000000b2', '00000000-0000-4000-8000-0000000000b1', 'TEST Kicking', 'technical', 1);

insert into public.players (id, squad_id, name, age) values
  ('00000000-0000-4000-8000-0000000000a3', '00000000-0000-4000-8000-0000000000a1', 'TEST Player A', 15),
  ('00000000-0000-4000-8000-0000000000b3', '00000000-0000-4000-8000-0000000000b1', 'TEST Player B', 15);

insert into public.coach_squads (coach_id, squad_id, is_lead) values
  ('00000000-0000-4000-8000-0000000000c1', '00000000-0000-4000-8000-0000000000a1', false),
  ('00000000-0000-4000-8000-0000000000c2', '00000000-0000-4000-8000-0000000000a1', true),
  ('00000000-0000-4000-8000-0000000000c3', '00000000-0000-4000-8000-0000000000b1', false);

-- A grouped drill per squad (Left × 2, Right × 3, max 10 points), and
-- an ordinary drill in squad A.
insert into public.drills (id, name, attribute_id, config) values
  ('00000000-0000-4000-8000-0000000000a4', 'TEST Grouped A', '00000000-0000-4000-8000-0000000000a2',
   '{"attempts": 5, "groups": [{"label": "Left", "attempts": 2}, {"label": "Right", "attempts": 3}],
     "results": [{"label": "Hit", "points": 2}, {"label": "Miss", "points": 0}],
     "retake_enabled": false, "retake_label": "Retake", "tags": [], "cutoffs": [40, 60, 75, 90]}'),
  ('00000000-0000-4000-8000-0000000000b4', 'TEST Grouped B', '00000000-0000-4000-8000-0000000000b2',
   '{"attempts": 5, "groups": [{"label": "Left", "attempts": 2}, {"label": "Right", "attempts": 3}],
     "results": [{"label": "Hit", "points": 2}, {"label": "Miss", "points": 0}],
     "retake_enabled": false, "retake_label": "Retake", "tags": [], "cutoffs": [40, 60, 75, 90]}'),
  ('00000000-0000-4000-8000-0000000000a6', 'TEST Plain A', '00000000-0000-4000-8000-0000000000a2',
   '{"attempts": 2, "results": [{"label": "Hit", "points": 1}, {"label": "Miss", "points": 0}],
     "retake_enabled": false, "retake_label": "Retake", "tags": [], "cutoffs": [40, 60, 75, 90]}');

-- One existing grouped entry in squad B: Left 2, 2 = 4; Right 2, 0, 0 = 2.
insert into public.drill_entries (id, drill_id, player_id, attempts, recorded_by) values
  ('00000000-0000-4000-8000-0000000000b5', '00000000-0000-4000-8000-0000000000b4',
   '00000000-0000-4000-8000-0000000000b3', '[2, 2, 2, 0, 0]', '00000000-0000-4000-8000-0000000000c3');

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
  -- 1. Coach A saves a grouped run: Left 2, 0 = 2 of 4; Right 2, 2, 0 = 4 of 6.
  --    Made-up subtotals sent by the app are replaced by the database's.
  insert into drill_entries (drill_id, player_id, attempts, group_totals) values
    ('00000000-0000-4000-8000-0000000000a4', '00000000-0000-4000-8000-0000000000a3',
     '[2, 0, 2, 2, 0]', '[{"label": "Left", "total": 99, "max": 99}]')
  returning * into e;

  if e.group_totals is distinct from
     '[{"label": "Left", "total": 2, "max": 4}, {"label": "Right", "total": 4, "max": 6}]'::jsonb then
    raise exception 'TEST 1 FAILED: expected Left 2 / 4 and Right 4 / 6, got %.', e.group_totals;
  end if;

  -- 2. The combined total and level come from all attempts together:
  --    6 of 10 = 60% → level 3.
  if e.total <> 6 or e.level <> 3 then
    raise exception 'TEST 2 FAILED: expected total 6 and level 3, got total % and level %.', e.total, e.level;
  end if;

  -- 3. One run adds one score (level 3), not one per group.
  if (select count(*) from scores
      where player_id = '00000000-0000-4000-8000-0000000000a3'
        and attribute_id = '00000000-0000-4000-8000-0000000000a2'
        and value = 3) <> 1 then
    raise exception 'TEST 3 FAILED: expected exactly one score of 3 for the grouped run.';
  end if;

  -- 4. A drill without groups saves no subtotals, as before.
  insert into drill_entries (drill_id, player_id, attempts) values
    ('00000000-0000-4000-8000-0000000000a6', '00000000-0000-4000-8000-0000000000a3', '[1, 0]')
  returning * into e;
  if e.group_totals is not null or e.total <> 1 then
    raise exception 'TEST 4 FAILED: plain drill gave total % and subtotals %.', e.total, e.group_totals;
  end if;
end $$;

do $$
begin
  -- 5. Coach A can't see squad B's grouped entry (or its subtotals).
  if (select count(*) from drill_entries
      where id = '00000000-0000-4000-8000-0000000000b5') <> 0 then
    raise exception 'TEST 5 FAILED: Coach A can see squad B''s grouped entry.';
  end if;

  -- 6. Coach A can't save a grouped run for squad B's player.
  begin
    insert into drill_entries (drill_id, player_id, attempts) values
      ('00000000-0000-4000-8000-0000000000b4', '00000000-0000-4000-8000-0000000000b3', '[2, 2, 2, 2, 2]');
    raise exception 'TEST 6 FAILED: Coach A saved a grouped run for squad B.';
  exception
    when raise_exception then
      if sqlerrm like 'TEST 6 FAILED%' then raise; end if;
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
  bad jsonb;
begin
  -- 7. Lead A can create a grouped drill.
  insert into drills (name, attribute_id, config) values
    ('Lead grouped drill', '00000000-0000-4000-8000-0000000000a2',
     '{"attempts": 10, "groups": [{"label": "Left", "attempts": 5}, {"label": "Right", "attempts": 5}],
       "results": [{"label": "Hit", "points": 1}], "retake_enabled": false, "retake_label": "Retake",
       "tags": [], "cutoffs": [30, 50, 70, 80]}');

  -- 8. Badly set-up groups are refused: attempts that don't add up,
  --    the same name twice, only one group, and groups on a timed drill.
  foreach bad in array array[
    '{"attempts": 9, "groups": [{"label": "Left", "attempts": 5}, {"label": "Right", "attempts": 5}],
      "results": [{"label": "Hit", "points": 1}], "retake_enabled": false, "retake_label": "Retake",
      "tags": [], "cutoffs": [30, 50, 70, 80]}',
    '{"attempts": 10, "groups": [{"label": "Left", "attempts": 5}, {"label": "left", "attempts": 5}],
      "results": [{"label": "Hit", "points": 1}], "retake_enabled": false, "retake_label": "Retake",
      "tags": [], "cutoffs": [30, 50, 70, 80]}',
    '{"attempts": 5, "groups": [{"label": "Left", "attempts": 5}],
      "results": [{"label": "Hit", "points": 1}], "retake_enabled": false, "retake_label": "Retake",
      "tags": [], "cutoffs": [30, 50, 70, 80]}',
    '{"measure": "time", "tags": [], "time_cutoffs": [80, 72, 66, 60],
      "groups": [{"label": "Left", "attempts": 1}, {"label": "Right", "attempts": 1}]}'
  ]::jsonb[] loop
    begin
      insert into drills (name, attribute_id, config) values
        ('Bad grouped drill', '00000000-0000-4000-8000-0000000000a2', bad);
      raise exception 'TEST 8 FAILED: a badly set-up grouped drill was accepted: %', bad;
    exception
      when raise_exception then
        if sqlerrm like 'TEST 8 FAILED%' then raise; end if;
      when check_violation then null;  -- refused, as intended
    end;
  end loop;
end $$;

-- =====================================================================
-- As COACH B (squad B)
-- =====================================================================
select set_config('request.jwt.claims',
  '{"sub": "00000000-0000-4000-8000-0000000000c3", "role": "authenticated"}', true);

do $$
begin
  -- 9. Coach B sees their own grouped entry with its subtotals:
  --    Left 4 / 4, Right 2 / 6; 6 of 10 → level 3.
  if not exists (
    select 1 from drill_entries
    where id = '00000000-0000-4000-8000-0000000000b5'
      and level = 3
      and group_totals = '[{"label": "Left", "total": 4, "max": 4}, {"label": "Right", "total": 2, "max": 6}]'::jsonb
  ) then
    raise exception 'TEST 9 FAILED: Coach B can''t see their own grouped entry with the right subtotals.';
  end if;

  -- 10. Coach B sees none of squad A's entries.
  if (select count(*) from drill_entries
      where player_id = '00000000-0000-4000-8000-0000000000a3') <> 0 then
    raise exception 'TEST 10 FAILED: Coach B can see squad A''s entries.';
  end if;
end $$;

-- =====================================================================
-- All passed: stop on purpose so everything above is undone.
-- =====================================================================
do $$
begin
  raise exception 'ALL 10 ATTEMPT GROUP TESTS PASSED. (This is shown as an error on purpose: it undoes all the pretend test data, so nothing is kept.)';
end $$;

rollback;

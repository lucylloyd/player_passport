-- =====================================================================
-- Tests for the drills migration (2026-11-12-drills.sql)
--
-- Run AFTER the migration, as one go, in the Supabase SQL Editor.
--
-- What it does, in plain language:
--   - Creates two pretend squads (A and B), a player in each, and three
--     pretend coaches: Coach A (squad A), Lead A (lead of squad A) and
--     Coach B (squad B).
--   - Signs in as each pretend coach in turn and checks what they can
--     and can't see or do.
--   - Then deliberately stops with a message, which UNDOES EVERYTHING.
--     None of the pretend data is kept.
--
-- How to read the result:
--   - "ALL 12 TESTS PASSED" (shown as an error, on purpose) = all good.
--   - "TEST n FAILED: ..." = a security rule isn't working as intended.
--     Don't merge the app change; send me the message.
--   - Any other error = something about the test setup didn't fit your
--     database (for example, how profiles are created). Send me the
--     message.
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
  ('00000000-0000-4000-8000-0000000000a2', '00000000-0000-4000-8000-0000000000a1', 'TEST Push pass', 'technical', 1),
  ('00000000-0000-4000-8000-0000000000b2', '00000000-0000-4000-8000-0000000000b1', 'TEST Push pass', 'technical', 1);

insert into public.players (id, squad_id, name, age) values
  ('00000000-0000-4000-8000-0000000000a3', '00000000-0000-4000-8000-0000000000a1', 'TEST Player A', 15),
  ('00000000-0000-4000-8000-0000000000b3', '00000000-0000-4000-8000-0000000000b1', 'TEST Player B', 15);

insert into public.coach_squads (coach_id, squad_id, is_lead) values
  ('00000000-0000-4000-8000-0000000000c1', '00000000-0000-4000-8000-0000000000a1', false),
  ('00000000-0000-4000-8000-0000000000c2', '00000000-0000-4000-8000-0000000000a1', true),
  ('00000000-0000-4000-8000-0000000000c3', '00000000-0000-4000-8000-0000000000b1', false);

-- One drill per squad: 5 attempts, Hit = 3, Close = 1, Miss = 0 (max 15).
insert into public.drills (id, name, attribute_id, config) values
  ('00000000-0000-4000-8000-0000000000a4', 'TEST Drill A', '00000000-0000-4000-8000-0000000000a2',
   '{"attempts": 5, "results": [{"label": "Hit", "points": 3}, {"label": "Close", "points": 1}, {"label": "Miss", "points": 0}],
     "retake_enabled": true, "retake_label": "Retake", "tags": [], "cutoffs": [40, 60, 75, 90]}'),
  ('00000000-0000-4000-8000-0000000000b4', 'TEST Drill B', '00000000-0000-4000-8000-0000000000b2',
   '{"attempts": 5, "results": [{"label": "Hit", "points": 3}, {"label": "Close", "points": 1}, {"label": "Miss", "points": 0}],
     "retake_enabled": true, "retake_label": "Retake", "tags": [], "cutoffs": [40, 60, 75, 90]}');

-- One existing entry per squad.
insert into public.drill_entries (id, drill_id, player_id, attempts, recorded_by) values
  ('00000000-0000-4000-8000-0000000000a5', '00000000-0000-4000-8000-0000000000a4',
   '00000000-0000-4000-8000-0000000000a3', '[3, 3, 3, 1, 0]', '00000000-0000-4000-8000-0000000000c1'),
  ('00000000-0000-4000-8000-0000000000b5', '00000000-0000-4000-8000-0000000000b4',
   '00000000-0000-4000-8000-0000000000b3', '[3, 3, 3, 1, 0]', '00000000-0000-4000-8000-0000000000c3');

-- From here on, act as a signed-in coach (RLS applies).
set local role authenticated;

-- =====================================================================
-- As COACH A (squad A, not a lead)
-- =====================================================================
select set_config('request.jwt.claims',
  '{"sub": "00000000-0000-4000-8000-0000000000c1", "role": "authenticated"}', true);

do $$
begin
  -- 1. Coach A can see their own squad's entry.
  if (select count(*) from drill_entries
      where id = '00000000-0000-4000-8000-0000000000a5') <> 1 then
    raise exception 'TEST 1 FAILED: Coach A cannot see an entry for their own squad.';
  end if;

  -- 2. Coach A cannot see squad B's entry (the key test).
  if (select count(*) from drill_entries
      where id = '00000000-0000-4000-8000-0000000000b5') <> 0 then
    raise exception 'TEST 2 FAILED: Coach A can see an entry from squad B.';
  end if;
  if (select count(*) from drill_entries
      where player_id = '00000000-0000-4000-8000-0000000000b3') <> 0 then
    raise exception 'TEST 2 FAILED: Coach A can see squad B''s player entries.';
  end if;

  -- 3. Coach A sees squad A's drill but not squad B's.
  if (select count(*) from drills where id = '00000000-0000-4000-8000-0000000000a4') <> 1
     or (select count(*) from drills where id = '00000000-0000-4000-8000-0000000000b4') <> 0 then
    raise exception 'TEST 3 FAILED: Coach A sees the wrong drills.';
  end if;
end $$;

do $$
begin
  -- 4. Coach A cannot record an entry for squad B's player.
  begin
    insert into drill_entries (drill_id, player_id, attempts) values
      ('00000000-0000-4000-8000-0000000000b4', '00000000-0000-4000-8000-0000000000b3', '[3, 3, 3, 3, 3]');
    raise exception 'TEST 4 FAILED: Coach A recorded an entry for squad B.';
  exception
    when raise_exception then
      if sqlerrm like 'TEST 4 FAILED%' then raise; end if;
    when others then null;  -- blocked, as intended
  end;

  -- 5. Coach A cannot use their own drill on squad B's player either.
  begin
    insert into drill_entries (drill_id, player_id, attempts) values
      ('00000000-0000-4000-8000-0000000000a4', '00000000-0000-4000-8000-0000000000b3', '[3, 3, 3, 3, 3]');
    raise exception 'TEST 5 FAILED: Coach A ran squad A''s drill on a squad B player.';
  exception
    when raise_exception then
      if sqlerrm like 'TEST 5 FAILED%' then raise; end if;
    when others then null;  -- blocked, as intended
  end;
end $$;

do $$
declare
  e record;
begin
  -- 6. Coach A can record an entry for their own player. The database
  --    works out the total and level, ignoring what was sent.
  --    [3, 3, 1, 1, 0] = 8 out of 15 = 53% → level 2 (40% or more, under 60%).
  insert into drill_entries (drill_id, player_id, attempts, total, level) values
    ('00000000-0000-4000-8000-0000000000a4', '00000000-0000-4000-8000-0000000000a3',
     '[3, 3, 1, 1, 0]', 99, 5)
  returning * into e;

  if e.total <> 8 or e.level <> 2 then
    raise exception 'TEST 6 FAILED: expected total 8 and level 2, got total % and level %.', e.total, e.level;
  end if;
  if e.recorded_by <> '00000000-0000-4000-8000-0000000000c1' then
    raise exception 'TEST 6 FAILED: the entry was not recorded as Coach A.';
  end if;

  -- 7. Saving that entry added a matching score (level 2) for the
  --    drill's attribute.
  if not exists (
    select 1 from scores
    where player_id = '00000000-0000-4000-8000-0000000000a3'
      and attribute_id = '00000000-0000-4000-8000-0000000000a2'
      and value = 2
      and scored_by = '00000000-0000-4000-8000-0000000000c1'
  ) then
    raise exception 'TEST 7 FAILED: no matching score was added.';
  end if;
end $$;

do $$
declare
  n int;
begin
  -- 8. Coach A (not a lead) cannot create a drill...
  begin
    insert into drills (name, attribute_id) values
      ('Sneaky drill', '00000000-0000-4000-8000-0000000000a2');
    raise exception 'TEST 8 FAILED: Coach A (not a lead) created a drill.';
  exception
    when raise_exception then
      if sqlerrm like 'TEST 8 FAILED%' then raise; end if;
    when others then null;  -- blocked, as intended
  end;

  -- ...or edit one (the update quietly matches no rows).
  update drills set name = 'Renamed' where id = '00000000-0000-4000-8000-0000000000a4';
  get diagnostics n = row_count;
  if n <> 0 then
    raise exception 'TEST 8 FAILED: Coach A (not a lead) edited a drill.';
  end if;
end $$;

-- =====================================================================
-- As LEAD A (lead of squad A)
-- =====================================================================
select set_config('request.jwt.claims',
  '{"sub": "00000000-0000-4000-8000-0000000000c2", "role": "authenticated"}', true);

do $$
declare
  d record;
  n int;
begin
  -- 9. Lead A can create a drill for squad A, and it's placed in squad A
  --    automatically (from its attribute).
  insert into drills (name, attribute_id) values
    ('Lead drill', '00000000-0000-4000-8000-0000000000a2')
  returning * into d;
  if d.squad_id <> '00000000-0000-4000-8000-0000000000a1' then
    raise exception 'TEST 9 FAILED: the new drill was not placed in squad A.';
  end if;

  -- 10. Lead A can edit squad A's drill.
  update drills set name = 'Renamed by lead' where id = '00000000-0000-4000-8000-0000000000a4';
  get diagnostics n = row_count;
  if n <> 1 then
    raise exception 'TEST 10 FAILED: Lead A could not edit their squad''s drill.';
  end if;

  -- 11. Lead A cannot create a drill for squad B.
  begin
    insert into drills (name, attribute_id) values
      ('Wrong squad drill', '00000000-0000-4000-8000-0000000000b2');
    raise exception 'TEST 11 FAILED: Lead A created a drill for squad B.';
  exception
    when raise_exception then
      if sqlerrm like 'TEST 11 FAILED%' then raise; end if;
    when others then null;  -- blocked, as intended
  end;
end $$;

-- =====================================================================
-- As COACH B (squad B)
-- =====================================================================
select set_config('request.jwt.claims',
  '{"sub": "00000000-0000-4000-8000-0000000000c3", "role": "authenticated"}', true);

do $$
begin
  -- 12. Coach B sees only squad B's entry, none of squad A's.
  if (select count(*) from drill_entries
      where player_id = '00000000-0000-4000-8000-0000000000a3') <> 0 then
    raise exception 'TEST 12 FAILED: Coach B can see squad A''s entries.';
  end if;
  if (select count(*) from drill_entries
      where id = '00000000-0000-4000-8000-0000000000b5') <> 1 then
    raise exception 'TEST 12 FAILED: Coach B cannot see their own squad''s entry.';
  end if;
end $$;

-- =====================================================================
-- All passed: stop on purpose so everything above is undone.
-- =====================================================================
do $$
begin
  raise exception 'ALL 12 TESTS PASSED. (This is shown as an error on purpose: it undoes all the pretend test data, so nothing is kept.)';
end $$;

rollback;

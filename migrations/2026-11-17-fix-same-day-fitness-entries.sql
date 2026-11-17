-- =====================================================================
-- Data fix: three Fitness-male runs entered for the wrong date
-- Date: 2026-11-17
--
-- What this does, in plain language:
--   One goalkeeper ran the Fitness-male test three times on 13 Nov 2026.
--   They were entered (before the app fix of 2026-11-17) as:
--     - all dated 8 Nov, all at exactly 12:00, so the app couldn't tell
--       which run came last, and
--     - the third run typed as 3559 seconds instead of 59.
--   This file:
--     1. Backs up drill_entries and scores.
--     2. Moves the three runs to 13 Nov, a minute apart in the order
--        they were run: 65 s (12:00), then 63 s (12:01), then 59 s (12:02).
--     3. Corrects 3559 to 59 seconds.
--     4. Recalculates each run's level from the drill's cut-offs:
--        65 s → 3, 63 s → 3, 59 s → 4.
--     5. Moves each run's matching score with it (same date and level),
--        so the 59 s run (level 4) becomes the current score.
--   The 13 Oct run (67 s) isn't touched.
--
-- The player isn't named in this file because the repository may be
-- public. The runs are found by drill, date and times instead, and the
-- file stops without changing anything unless it finds exactly those
-- three runs for one player.
--
-- Run the whole file in one go in the Supabase SQL Editor. If anything
-- doesn't match, it stops and nothing is changed.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- Step 1: backups.
-- ---------------------------------------------------------------------
create schema if not exists backups;
create table backups.drill_entries_fitness_fix_2026_11_17 as table public.drill_entries;
alter table backups.drill_entries_fitness_fix_2026_11_17 enable row level security;
create table backups.scores_fitness_fix_2026_11_17 as table public.scores;
alter table backups.scores_fitness_fix_2026_11_17 enable row level security;

-- ---------------------------------------------------------------------
-- Steps 2–5: fix the three runs and their scores.
-- ---------------------------------------------------------------------
do $$
declare
  old_ts   constant timestamptz := '2026-11-08 12:00:00+00';  -- how they were saved
  new_day  constant timestamptz := '2026-11-13 12:00:00+00';  -- 13 Nov, midday (GMT)
  v_drill  uuid;
  v_attr   uuid;
  v_cutoffs jsonb;
  v_player uuid;
  e        record;
  n        int := 0;
  new_time numeric;
  new_ts   timestamptz;
  new_level int;
  v_score  uuid;
begin
  -- The Fitness-male drill (must be exactly one).
  if (select count(*) from drills where name = 'Fitness-male') <> 1 then
    raise exception 'Expected exactly one drill called Fitness-male. Nothing was changed.';
  end if;
  select id, attribute_id, config->'time_cutoffs'
    into v_drill, v_attr, v_cutoffs
  from drills where name = 'Fitness-male';

  -- The player: whoever has the mistyped 3559-second run on 8 Nov.
  if (select count(*) from drill_entries
      where drill_id = v_drill and recorded_at = old_ts and time_seconds = 3559) <> 1 then
    raise exception 'Expected exactly one 3559-second run on 8 Nov. It may already be fixed. Nothing was changed.';
  end if;
  select player_id into v_player
  from drill_entries
  where drill_id = v_drill and recorded_at = old_ts and time_seconds = 3559;

  -- That player must have exactly the three runs 65, 63 and 3559 on 8 Nov.
  if (select array_agg(time_seconds order by time_seconds) from drill_entries
      where drill_id = v_drill and player_id = v_player and recorded_at = old_ts)
     is distinct from array[63, 65, 3559]::numeric[] then
    raise exception 'The 8 Nov runs aren''t exactly 63, 65 and 3559 seconds. Nothing was changed.';
  end if;

  -- In the order they were run: 65, then 63, then 3559 (really 59).
  for e in
    select id, time_seconds, level
    from drill_entries
    where drill_id = v_drill and player_id = v_player and recorded_at = old_ts
    order by case time_seconds when 65 then 1 when 63 then 2 else 3 end
  loop
    new_time  := case when e.time_seconds = 3559 then 59 else e.time_seconds end;
    new_ts    := new_day + n * interval '1 minute';
    new_level := drill_time_level(new_time, v_cutoffs);
    n := n + 1;

    -- This run's score: same player, attribute, old date and old level.
    -- (Two runs share level 3; their scores are identical, so either one
    -- is fine. Once moved, a score no longer matches the old date.)
    select id into v_score
    from scores
    where player_id = v_player and attribute_id = v_attr
      and scored_at = old_ts and value = e.level
    limit 1;
    if v_score is null then
      raise exception 'Couldn''t find the score for the % second run. Nothing was changed.', e.time_seconds;
    end if;

    update scores
    set scored_at = new_ts, value = new_level
    where id = v_score;

    update drill_entries
    set time_seconds = new_time, level = new_level, recorded_at = new_ts
    where id = e.id;
  end loop;
end $$;

commit;

-- =====================================================================
-- AFTER check (runs automatically at the end of the file).
-- Expect 4 rows for the goalkeeper:
--   13 Oct 13:00 · 67 s · level 3
--   13 Nov 12:00 · 65 s · level 3
--   13 Nov 12:01 · 63 s · level 3
--   13 Nov 12:02 · 59 s · level 4
-- with score_matches true on every row.
-- =====================================================================
select (e.recorded_at at time zone 'Europe/London') as saved_for,
       e.time_seconds,
       e.level,
       exists (
         select 1 from scores sc
         where sc.player_id = e.player_id and sc.attribute_id = d.attribute_id
           and sc.scored_at = e.recorded_at and sc.value = e.level
       ) as score_matches
from drill_entries e
join drills d on d.id = e.drill_id
where d.name = 'Fitness-male'
  and e.player_id = (select player_id from drill_entries
                     where recorded_at = '2026-11-13 12:02:00+00' and time_seconds = 59
                     limit 1)
order by e.recorded_at;

-- =====================================================================
-- UNDO (only if something went wrong): copy into a new tab and run.
-- Puts both tables back exactly as they were before this file.
-- =====================================================================
--
-- begin;
-- update public.drill_entries e set time_seconds = b.time_seconds, level = b.level, recorded_at = b.recorded_at
--   from backups.drill_entries_fitness_fix_2026_11_17 b where b.id = e.id
--   and (e.time_seconds, e.level, e.recorded_at) is distinct from (b.time_seconds, b.level, b.recorded_at);
-- update public.scores s set value = b.value, scored_at = b.scored_at
--   from backups.scores_fitness_fix_2026_11_17 b where b.id = s.id
--   and (s.value, s.scored_at) is distinct from (b.value, b.scored_at);
-- commit;

-- =====================================================================
-- Migration: change the scoring scale from 1–4 to 1–5
-- Date: 2026-11-12
--
-- What this does, in plain language:
--   1. Saves a full copy of the scores table (a backup) before anything
--      changes.
--   2. Moves every existing score onto the new 5-level scale:
--        1 → 1  (Unmet   → Not yet)
--        2 → 2  (OK      → Developing)
--        3 → 4  (Better  → Strong)
--        4 → 5  (Best    → Excellent)
--      Level 3 (Secure) is new, so no existing score lands on it.
--   3. Adds a rule so the database only accepts scores from 1 to 5.
--
-- The old 3-level "outcomes" scale has been removed from the app. If any
-- real squad still has an attribute in the "outcomes" category, this
-- migration stops and changes nothing, so those scores aren't
-- converted by mistake.
--
-- When to run it: just before merging the app change, at a time when
-- no coach is scoring. Run the whole file in one go in the Supabase
-- SQL Editor. If any step fails, nothing is changed.
--
-- BEFORE running, use the "before" check further down in this file
-- (copy it into a new SQL Editor tab), and note the numbers.
-- =====================================================================

begin;

-- Safety checks: stop (changing nothing) if either is true.
do $$
begin
  -- Running it twice would push every 4 up to 5 a second time.
  if exists (
    select 1 from pg_constraint
    where conrelid = 'public.scores'::regclass
      and conname = 'scores_value_1_to_5'
  ) then
    raise exception 'This migration has already been run. Nothing was changed.';
  end if;

  -- The app no longer has an "outcomes" scale.
  if exists (
    select 1 from public.attributes
    where lower(category) = 'outcomes'
  ) then
    raise exception 'Some attributes are still in the "outcomes" category. Nothing was changed. Run the before check to see which ones.';
  end if;
end $$;

-- Step 1: backup. A full copy of scores, kept out of the app's reach.
create schema if not exists backups;
create table backups.scores_2026_11_12 as table public.scores;

-- Step 2: remove the old rule that only allows scores from 1 to 4
-- (it would block the new 5s). Its definition was:
--   CHECK (((value >= 1) AND (value <= 4)))
alter table public.scores drop constraint if exists scores_value_check;

-- Step 3: convert existing scores.
-- This is one statement, so each score is converted exactly once:
-- a 3 becomes a 4, and is not then turned into a 5.
update public.scores
set value = case value
              when 3 then 4
              when 4 then 5
            end
where value in (3, 4);

-- Step 4: only allow scores from 1 to 5 from now on.
alter table public.scores
  add constraint scores_value_1_to_5 check (value between 1 and 5);

commit;

-- =====================================================================
-- AFTER check (this runs automatically at the end of the file)
-- Compares every score with its backed-up copy. You should see:
--   old 1 → new 1, old 2 → new 2, old 3 → new 4, old 4 → new 5
-- with every row showing "ok". Any "MISMATCH" means something
-- unexpected happened: stop and ask before doing anything else.
-- The "scores" counts should match the before check.
-- =====================================================================
select
  b.value  as old_value,
  s.value  as new_value,
  count(*) as scores,
  case
    when s.value = case b.value when 3 then 4 when 4 then 5 else b.value end then 'ok'
    else 'MISMATCH'
  end      as result
from backups.scores_2026_11_12 b
join public.scores s on s.id = b.id
group by 1, 2, 4
order by 1;


-- =====================================================================
-- BEFORE check: copy everything below into a NEW SQL Editor tab and
-- run each query BEFORE the migration. They change nothing.
-- =====================================================================
--
-- -- 1. How many scores there are at each value.
-- --    Note these numbers down to compare with the after check.
-- select value, count(*) as scores
-- from public.scores
-- group by value
-- order by value;
--
-- -- 2. Any scores outside 1–4 (should return no rows; if it does,
-- --    the new 1–5 rule would fail, so ask before running).
-- select *
-- from public.scores
-- where value not between 1 and 4;
--
-- -- 3. Any real "outcomes" attributes (should return no rows; if it
-- --    does, the migration will stop, so ask before running).
-- select s.name as squad, a.name as attribute, a.id
-- from public.attributes a
-- join public.squads s on s.id = a.squad_id
-- where lower(a.category) = 'outcomes';
--
-- -- 4. Existing rules on score values. Expected result:
-- --    scores_value_check  CHECK (((value >= 1) AND (value <= 4)))
-- --    The migration replaces it. If anything else shows, ask first.
-- select conname, pg_get_constraintdef(oid)
-- from pg_constraint
-- where conrelid = 'public.scores'::regclass and contype = 'c';
--
-- =====================================================================
-- UNDO (only if something went wrong): copy into a new tab and run.
-- =====================================================================
--
-- begin;
-- alter table public.scores drop constraint if exists scores_value_1_to_5;
-- truncate public.scores;
-- insert into public.scores select * from backups.scores_2026_11_12;
-- alter table public.scores
--   add constraint scores_value_check check (value >= 1 and value <= 4);
-- commit;
--
-- After an undo, the app change must NOT be merged (or must be reverted),
-- because the old 1–4 scores would show with the new 1–5 labels.

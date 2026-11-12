-- =====================================================================
-- Migration: change the scoring scale from 1–4 to 1–5
-- Date: 2026-11-12
--
-- What this does, in plain language:
--   1. Saves a full copy of the scores table (a backup) before anything
--      changes.
--   2. Moves existing scores onto the new 5-level scale:
--        1 → 1  (Unmet   → Not yet)
--        2 → 2  (OK      → Developing)
--        3 → 4  (Better  → Strong)
--        4 → 5  (Best    → Excellent)
--      Level 3 (Secure) is new, so no existing score lands on it.
--   3. Adds a rule so the database only accepts scores from 1 to 5.
--
-- Scores for the "outcomes" category are NOT converted. That category
-- still uses its own 3-level scale (Missing / Attempting / Achieving).
--
-- When to run it: just before merging the app change, at a time when
-- no coach is scoring. Run the whole file in one go in the Supabase
-- SQL Editor. If any step fails, nothing is changed.
--
-- BEFORE running, use the "before" check further down in this file
-- (copy it into a new SQL Editor tab), and note the numbers.
-- =====================================================================

begin;

-- Safety check: stop if this migration has already been run.
-- Running it twice would push every 4 up to 5 a second time.
do $$
begin
  if exists (
    select 1 from pg_constraint
    where conrelid = 'public.scores'::regclass
      and conname = 'scores_value_1_to_5'
  ) then
    raise exception 'This migration has already been run. Nothing was changed.';
  end if;
end $$;

-- Step 1: backup. A full copy of scores, kept out of the app's reach.
create schema if not exists backups;
create table backups.scores_2026_11_12 as table public.scores;

-- Step 2: remove any existing rule that limits score values
-- (for example an old "between 1 and 4" rule, which would block 5s).
do $$
declare
  c record;
begin
  for c in
    select conname from pg_constraint
    where conrelid = 'public.scores'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%value%'
  loop
    execute format('alter table public.scores drop constraint %I', c.conname);
  end loop;
end $$;

-- Step 3: convert existing scores (all categories except "outcomes").
-- This is one statement, so each score is converted exactly once:
-- a 3 becomes a 4, and is not then turned into a 5.
update public.scores s
set value = case s.value
              when 3 then 4
              when 4 then 5
              else s.value
            end
from public.attributes a
where a.id = s.attribute_id
  and coalesce(lower(a.category), '') <> 'outcomes'
  and s.value in (3, 4);

-- Step 4: only allow scores from 1 to 5 from now on.
alter table public.scores
  add constraint scores_value_1_to_5 check (value between 1 and 5);

commit;

-- =====================================================================
-- AFTER check (this runs automatically at the end of the file)
-- Compares every score with its backed-up copy. Every row should show
-- "ok". Any row showing "MISMATCH" means something unexpected happened:
-- stop and ask before doing anything else.
-- =====================================================================
select
  case when coalesce(lower(a.category), '') = 'outcomes' then 'outcomes (unchanged)'
       else 'converted' end                       as scale,
  b.value                                         as old_value,
  s.value                                         as new_value,
  count(*)                                        as scores,
  case
    when coalesce(lower(a.category), '') = 'outcomes' and s.value = b.value then 'ok'
    when coalesce(lower(a.category), '') <> 'outcomes'
         and s.value = case b.value when 3 then 4 when 4 then 5 else b.value end then 'ok'
    else 'MISMATCH'
  end                                             as result
from backups.scores_2026_11_12 b
join public.scores s     on s.id = b.id
join public.attributes a on a.id = s.attribute_id
group by 1, 2, 3, 5
order by 1, 2;


-- =====================================================================
-- BEFORE check: copy everything below into a NEW SQL Editor tab and
-- run it BEFORE the migration. It changes nothing.
-- =====================================================================
--
-- -- 1. How many scores there are at each value.
-- --    Note these numbers down to compare with the after check.
-- select
--   case when coalesce(lower(a.category), '') = 'outcomes' then 'outcomes (unchanged)'
--        else 'will be converted' end as scale,
--   s.value,
--   count(*) as scores
-- from public.scores s
-- join public.attributes a on a.id = s.attribute_id
-- group by 1, 2
-- order by 1, 2;
--
-- -- 2. Any scores outside 1–4 (should return no rows; if it does,
-- --    the new 1–5 rule would fail, so ask before running).
-- select s.*
-- from public.scores s
-- where s.value not between 1 and 4;
--
-- -- 3. Any existing rules on score values (the migration replaces them).
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
-- commit;
--
-- After an undo, the app change must NOT be merged (or must be reverted),
-- because the old 1–4 scores would show with the new 1–5 labels.

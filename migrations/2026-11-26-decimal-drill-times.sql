-- =====================================================================
-- Migration: timed drills can use seconds with decimals
-- Date: 2026-11-26
--
-- What this does, in plain language:
--   1. Backs up the drills and drill_entries tables.
--   2. A timed drill gets a "time format" setting, stored in its
--      existing settings (drills.config) as "time_format":
--        "min_sec" - minutes and seconds, e.g. 1:07 (as now)
--        "decimal" - seconds with up to 2 decimal places, e.g. 8.45,
--                    for sprint and agility tests
--      Drills without it are "min_sec", so existing drills carry on
--      exactly as before.
--   3. For a "decimal" drill, the level cut-offs can have up to 2
--      decimal places (e.g. 8.50). "min_sec" drills still use whole
--      seconds. Everything else in the settings check is unchanged
--      from 2026-11-17-drill-attempt-groups.sql.
--   4. A saved time (drill_entries.time_seconds) can have at most 2
--      decimal places. It was already a decimal number column, so no
--      column changes are needed, and every time saved so far is a
--      whole number of seconds, which still passes.
--
-- The level rule (drill_time_level) already compares decimal numbers,
-- so it needs no change: 8.45 seconds against a cut-off of 8.50 gets
-- that level.
--
-- Security (RLS): no policy changes. Nothing new is added that people
-- can read or write; the existing drills and drill_entries rules still
-- decide who sees and adds which rows.
--
-- Run the whole file in one go in the Supabase SQL Editor. If any step
-- fails, nothing is changed. Run it BEFORE merging the app update.
-- The current app keeps working after this runs (it simply doesn't
-- offer the new setting yet), so there's no rush between the two.
--
-- BEFORE running, copy the "before" check at the bottom into a new tab.
-- =====================================================================

begin;

-- Safety check: stop if this migration has already been run.
do $$
begin
  if exists (
    select 1 from pg_constraint
    where conname = 'drill_entries_time_seconds_2dp'
  ) then
    raise exception 'drill_entries_time_seconds_2dp already exists, so this migration has already been run. Nothing was changed.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Step 1: backups.
-- ---------------------------------------------------------------------
create schema if not exists backups;
create table backups.drills_2026_11_26 as table public.drills;
alter table backups.drills_2026_11_26 enable row level security;
create table backups.drill_entries_2026_11_26 as table public.drill_entries;
alter table backups.drill_entries_2026_11_26 enable row level security;

-- ---------------------------------------------------------------------
-- Step 2: the settings check now understands "time_format".
-- Only the "Timed drills" part has changed.
-- (The existing drills_config_valid rule on the drills table uses this
-- function, so replacing it updates that rule.)
-- ---------------------------------------------------------------------
create or replace function public.drill_config_is_valid(c jsonb)
returns boolean
language plpgsql
immutable
set search_path = public
as $$
declare
  prev numeric;
  x jsonb;
  v numeric;
  is_decimal boolean;
begin
  if jsonb_typeof(c) is distinct from 'object' then return false; end if;

  -- measure: missing (older drills) or "attempts" or "time"
  if c ? 'measure' and (c->>'measure') is distinct from 'attempts'
                   and (c->>'measure') is distinct from 'time' then
    return false;
  end if;

  -- quick tags (both kinds): a list of text
  if jsonb_typeof(c->'tags') is distinct from 'array' then return false; end if;
  if exists (select 1 from jsonb_array_elements(c->'tags') t where jsonb_typeof(t) <> 'string') then return false; end if;

  -- ---- Timed drills ----
  if c->>'measure' = 'time' then
    if c ? 'groups' then return false; end if;  -- timed drills have no groups

    -- time_format (new): missing, "min_sec" or "decimal"
    if c ? 'time_format' and (c->>'time_format') is distinct from 'min_sec'
                         and (c->>'time_format') is distinct from 'decimal' then
      return false;
    end if;
    is_decimal := (c->>'time_format') = 'decimal';

    -- time_cutoffs: exactly 4 numbers of seconds, each SMALLER than the
    -- one before (lower is better), under 24 hours.
    --   min_sec: whole seconds, at least 1
    --   decimal: up to 2 decimal places, at least 0.01
    if jsonb_typeof(c->'time_cutoffs') is distinct from 'array' then return false; end if;
    if jsonb_array_length(c->'time_cutoffs') <> 4 then return false; end if;
    prev := 86400;
    for x in select * from jsonb_array_elements(c->'time_cutoffs') loop
      if jsonb_typeof(x) is distinct from 'number' then return false; end if;
      v := (x #>> '{}')::numeric;
      if is_decimal then
        if v <> round(v, 2) or v < 0.01 then return false; end if;
      else
        if v <> trunc(v) or v < 1 then return false; end if;
      end if;
      if v >= prev then return false; end if;
      prev := v;
    end loop;
    return true;
  end if;

  -- ---- Attempt drills (unchanged) ----
  prev := 0;

  -- attempts: whole number from 1 to 50
  if jsonb_typeof(c->'attempts') is distinct from 'number' then return false; end if;
  if (c->>'attempts')::numeric not between 1 and 50
     or (c->>'attempts')::numeric <> trunc((c->>'attempts')::numeric) then return false; end if;

  -- groups (optional): 2 to 6 groups, each with a label and a whole
  -- number of attempts (1–50), labels all different, and the group
  -- attempts adding up to "attempts"
  if c ? 'groups' then
    if jsonb_typeof(c->'groups') is distinct from 'array' then return false; end if;
    if jsonb_array_length(c->'groups') not between 2 and 6 then return false; end if;
    for x in select * from jsonb_array_elements(c->'groups') loop
      if jsonb_typeof(x->'label') is distinct from 'string' or length(trim(x->>'label')) = 0 then return false; end if;
      if jsonb_typeof(x->'attempts') is distinct from 'number' then return false; end if;
      if (x->>'attempts')::numeric not between 1 and 50
         or (x->>'attempts')::numeric <> trunc((x->>'attempts')::numeric) then return false; end if;
    end loop;
    if (select count(distinct lower(trim(g->>'label'))) from jsonb_array_elements(c->'groups') g)
       <> jsonb_array_length(c->'groups') then return false; end if;
    if (select sum((g->>'attempts')::numeric) from jsonb_array_elements(c->'groups') g)
       <> (c->>'attempts')::numeric then return false; end if;
  end if;

  -- results: 1 to 8 options, each with a label and whole points >= 0,
  -- and at least one option worth more than 0
  if jsonb_typeof(c->'results') is distinct from 'array' then return false; end if;
  if jsonb_array_length(c->'results') not between 1 and 8 then return false; end if;
  for x in select * from jsonb_array_elements(c->'results') loop
    if jsonb_typeof(x->'label') is distinct from 'string' or length(trim(x->>'label')) = 0 then return false; end if;
    if jsonb_typeof(x->'points') is distinct from 'number' then return false; end if;
    if (x->>'points')::numeric < 0 or (x->>'points')::numeric > 100
       or (x->>'points')::numeric <> trunc((x->>'points')::numeric) then return false; end if;
  end loop;
  if (select max((r->>'points')::numeric) from jsonb_array_elements(c->'results') r) <= 0 then return false; end if;

  -- retake on/off and its button label
  if jsonb_typeof(c->'retake_enabled') is distinct from 'boolean' then return false; end if;
  if jsonb_typeof(c->'retake_label') is distinct from 'string' then return false; end if;

  -- cut-offs: exactly 4 whole percentages, each higher than the last, 1–100
  if jsonb_typeof(c->'cutoffs') is distinct from 'array' then return false; end if;
  if jsonb_array_length(c->'cutoffs') <> 4 then return false; end if;
  for x in select * from jsonb_array_elements(c->'cutoffs') loop
    if jsonb_typeof(x) is distinct from 'number' then return false; end if;
    if (x #>> '{}')::numeric <> trunc((x #>> '{}')::numeric)
       or (x #>> '{}')::numeric <= prev
       or (x #>> '{}')::numeric > 100 then return false; end if;
    prev := (x #>> '{}')::numeric;
  end loop;

  return true;
end;
$$;

-- ---------------------------------------------------------------------
-- Step 3: a saved time can have at most 2 decimal places (8.45 is
-- fine, 8.456 is refused). Empty times (attempt drills) are fine.
-- ---------------------------------------------------------------------
alter table public.drill_entries
  add constraint drill_entries_time_seconds_2dp
  check (time_seconds is null or time_seconds = round(time_seconds, 2));

commit;

-- =====================================================================
-- AFTER check (runs automatically at the end of the file).
-- Expect every true/false column to be true, and the backed-up counts
-- to match the numbers from the before check.
-- =====================================================================
select
  -- Every existing drill still passes the settings check.
  (select bool_and(public.drill_config_is_valid(config)) is not false from public.drills) as existing_drills_valid,
  -- A decimal drill with 2-decimal cut-offs is now accepted...
  public.drill_config_is_valid('{"measure":"time","time_format":"decimal","tags":[],"time_cutoffs":[10,9.5,9,8.45]}') as decimal_drill_accepted,
  -- ...but 3 decimal places, decimals on a minutes-and-seconds drill,
  -- and an unknown format are refused.
  not public.drill_config_is_valid('{"measure":"time","time_format":"decimal","tags":[],"time_cutoffs":[10,9.5,9,8.455]}') as three_decimals_refused,
  not public.drill_config_is_valid('{"measure":"time","time_format":"min_sec","tags":[],"time_cutoffs":[80,72,66,60.5]}') as min_sec_decimals_refused,
  not public.drill_config_is_valid('{"measure":"time","time_format":"hours","tags":[],"time_cutoffs":[80,72,66,60]}') as unknown_format_refused,
  -- The level rule works with decimals: 8.45s against [10, 9.5, 9, 8.5] is level 5.
  public.drill_time_level(8.45, '[10, 9.5, 9, 8.5]'::jsonb) = 5 as decimal_level_works,
  -- RLS is still on, and both drill_entries rules are still there.
  (select relrowsecurity from pg_class where oid = 'public.drill_entries'::regclass) as rls_still_on,
  (select count(*) = 2 from pg_policies where tablename = 'drill_entries') as both_rules_present,
  (select count(*) from backups.drills_2026_11_26) as drills_backed_up,
  (select count(*) from backups.drill_entries_2026_11_26) as drill_entries_backed_up;


-- =====================================================================
-- BEFORE check: copy ONLY the lines below into a NEW SQL Editor tab,
-- remove the "-- " at the start of each, and run. It changes nothing.
-- Note the two numbers. "times_with_decimals" should be 0; if it isn't,
-- stop and ask before running this migration.
-- =====================================================================
--
-- select
--   (select count(*) from public.drills) as drills,
--   (select count(*) from public.drill_entries) as drill_entries,
--   (select count(*) from public.drill_entries
--     where time_seconds is not null and time_seconds <> round(time_seconds, 2)) as times_with_decimals;
--
-- =====================================================================
-- UNDO (only if something went wrong, and before any drill has been
-- set to "seconds with decimals"). Ask first. Afterwards, re-run the drill_config_is_valid
-- "create or replace" block from 2026-11-17-drill-attempt-groups.sql
-- to put the previous settings check back.
-- =====================================================================
--
-- begin;
-- alter table public.drill_entries drop constraint if exists drill_entries_time_seconds_2dp;
-- update public.drills set config = config - 'time_format' where config ? 'time_format';
-- commit;

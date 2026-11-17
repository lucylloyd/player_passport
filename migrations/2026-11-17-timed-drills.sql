-- =====================================================================
-- Migration: timed drills
-- Date: 2026-11-17
--
-- What this does, in plain language:
--   1. Backs up the drills and drill_entries tables.
--   2. A drill can now be measured by "Attempts" (as now) or by "Time"
--      (e.g. a 1km run). This is stored inside the drill's existing
--      settings (drills.config), so no new table is needed:
--        {"measure": "time", "tags": [...], "time_cutoffs": [80, 72, 66, 60]}
--      "time_cutoffs" are the SLOWEST time, in seconds, that still gets
--      levels 2, 3, 4 and 5. Lower is better, so each one is smaller
--      than the one before. With [80, 72, 66, 60]:
--        5 = 1:00 or under, 4 = up to 1:06, 3 = up to 1:12,
--        2 = up to 1:20, 1 = slower than 1:20.
--      Existing drills have no "measure", which means "attempts", so
--      they carry on exactly as before.
--   3. drill_entries gets a new "time_seconds" column for the time.
--      Attempt entries leave it empty. Timed entries leave the
--      attempts list empty and have no points total.
--   4. When an entry is saved, the database still works out the level
--      itself (now from the time, for timed drills) and still adds the
--      matching row to "scores", exactly as for attempt drills.
--   5. Once a drill has been run, it can't be switched between
--      Attempts and Time, so old entries keep making sense.
--
-- Security (RLS): no policy changes are needed. RLS rules in Postgres
-- decide which ROWS someone can see or add, not which columns, so the
-- existing "coach sees own squads" and "coach can insert for own
-- squads" rules on drill_entries automatically cover time_seconds.
-- The check at the bottom confirms the app's role can use the new
-- column, and 2026-11-17-timed-drills-tests.sql tests it as pretend
-- coaches.
--
-- Run the whole file in one go in the Supabase SQL Editor. If any step
-- fails, nothing is changed. Then run 2026-11-17-timed-drills-tests.sql.
--
-- BEFORE running, copy the "before" check at the bottom into a new tab.
-- =====================================================================

begin;

-- Safety check: stop if this migration has already been run.
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'drill_entries' and column_name = 'time_seconds'
  ) then
    raise exception 'drill_entries.time_seconds already exists, so this migration has already been run. Nothing was changed.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Step 1: backups.
-- ---------------------------------------------------------------------
create schema if not exists backups;
create table backups.drills_2026_11_17 as table public.drills;
alter table backups.drills_2026_11_17 enable row level security;
create table backups.drill_entries_2026_11_17 as table public.drill_entries;
alter table backups.drill_entries_2026_11_17 enable row level security;

-- ---------------------------------------------------------------------
-- Step 2: the new column, and loosen two columns timed entries don't use.
--   - time_seconds: the time in seconds (e.g. 1:06 is 66). Empty for
--     attempt drills. Must be more than 0 and under 24 hours.
--   - attempts: now defaults to an empty list (timed entries have none).
--   - total: can now be empty (timed entries have no points total).
-- ---------------------------------------------------------------------
alter table public.drill_entries
  add column time_seconds numeric
  constraint drill_entries_time_seconds_range check (time_seconds > 0 and time_seconds < 86400);

alter table public.drill_entries alter column attempts set default '[]'::jsonb;
alter table public.drill_entries alter column total drop not null;

-- ---------------------------------------------------------------------
-- Step 3: the settings check now understands both kinds of drill.
-- The attempts part is unchanged from 2026-11-12-drills.sql.
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
    -- time_cutoffs: exactly 4 whole numbers of seconds, each SMALLER
    -- than the one before (lower is better), from 1 second to 24 hours
    if jsonb_typeof(c->'time_cutoffs') is distinct from 'array' then return false; end if;
    if jsonb_array_length(c->'time_cutoffs') <> 4 then return false; end if;
    prev := 86400;
    for x in select * from jsonb_array_elements(c->'time_cutoffs') loop
      if jsonb_typeof(x) is distinct from 'number' then return false; end if;
      if (x #>> '{}')::numeric <> trunc((x #>> '{}')::numeric)
         or (x #>> '{}')::numeric < 1
         or (x #>> '{}')::numeric >= prev then return false; end if;
      prev := (x #>> '{}')::numeric;
    end loop;
    return true;
  end if;

  -- ---- Attempt drills (unchanged) ----
  prev := 0;

  -- attempts: whole number from 1 to 50
  if jsonb_typeof(c->'attempts') is distinct from 'number' then return false; end if;
  if (c->>'attempts')::numeric not between 1 and 50
     or (c->>'attempts')::numeric <> trunc((c->>'attempts')::numeric) then return false; end if;

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

-- Works out the level (1–5) from a time. Each cut-off the time is at or
-- under adds one level. The app uses the same rule (drillTimeLevel in
-- index.html).
create function public.drill_time_level(seconds numeric, time_cutoffs jsonb)
returns int
language sql
immutable
set search_path = public
as $$
  select 1 + (select count(*)::int
              from jsonb_array_elements(time_cutoffs) c
              where seconds <= (c #>> '{}')::numeric);
$$;

-- ---------------------------------------------------------------------
-- Step 4: once a drill has been run, it can't switch between Attempts
-- and Time. Everything else is unchanged from 2026-11-12-drills.sql.
-- ---------------------------------------------------------------------
create or replace function public.drills_before_write()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  select a.squad_id into new.squad_id
  from attributes a
  where a.id = new.attribute_id;

  if new.squad_id is null then
    raise exception 'That attribute could not be found.';
  end if;

  if tg_op = 'INSERT' then
    new.created_by := coalesce(auth.uid(), new.created_by);
    new.created_at := now();
  else
    new.created_by := old.created_by;
    new.created_at := old.created_at;
    if new.attribute_id <> old.attribute_id
       and exists (select 1 from drill_entries e where e.drill_id = old.id) then
      raise exception 'This drill has already been run, so its attribute can''t be changed. Create a new drill instead.';
    end if;
    if coalesce(new.config->>'measure', 'attempts') <> coalesce(old.config->>'measure', 'attempts')
       and exists (select 1 from drill_entries e where e.drill_id = old.id) then
      raise exception 'This drill has already been run, so it can''t be switched between Attempts and Time. Create a new drill instead.';
    end if;
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- Step 5: the drill-entry check now handles timed drills.
-- The attempts part, the archived check and the session date rules are
-- unchanged from 2026-11-12-session-date-and-archive.sql. The existing
-- after-insert step still adds the matching score (with this level and
-- the session date), so nothing changes there.
-- ---------------------------------------------------------------------
create or replace function public.drill_entries_before_insert()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  d record;
  max_total numeric;
begin
  select dr.squad_id, dr.attribute_id, dr.config into d
  from drills dr
  where dr.id = new.drill_id;

  if not found then
    raise exception 'That drill could not be found.';
  end if;

  if exists (
    select 1 from attributes a
    where a.id = d.attribute_id and a.archived_at is not null
  ) then
    raise exception 'This drill''s attribute has been archived, so the drill can''t be run.';
  end if;

  if not exists (
    select 1 from players p
    where p.id = new.player_id and p.squad_id = d.squad_id
  ) then
    raise exception 'This player is not in the drill''s squad.';
  end if;

  if d.config->>'measure' = 'time' then
    -- ---- Timed drill: the level comes from the time ----
    if new.time_seconds is null then
      raise exception 'This is a timed drill, so it needs a time.';
    end if;
    new.attempts := '[]'::jsonb;
    new.retakes := 0;
    new.total := null;
    new.level := drill_time_level(new.time_seconds, d.config->'time_cutoffs');
  else
    -- ---- Attempt drill (unchanged) ----
    new.time_seconds := null;

    if jsonb_typeof(new.attempts) is distinct from 'array'
       or jsonb_array_length(new.attempts) <> (d.config->>'attempts')::int then
      raise exception 'This drill needs exactly % attempts.', d.config->>'attempts';
    end if;

    if exists (
      select 1 from jsonb_array_elements(new.attempts) a
      where jsonb_typeof(a) <> 'number'
         or not exists (
           select 1 from jsonb_array_elements(d.config->'results') r
           where (r->>'points')::numeric = (a #>> '{}')::numeric
         )
    ) then
      raise exception 'Every attempt must be one of the drill''s result options.';
    end if;

    select max((r->>'points')::numeric) * (d.config->>'attempts')::numeric
      into max_total
    from jsonb_array_elements(d.config->'results') r;

    select coalesce(sum((a #>> '{}')::numeric), 0)::int
      into new.total
    from jsonb_array_elements(new.attempts) a;

    new.level := drill_level(new.total, max_total, d.config->'cutoffs');

    if not (d.config->>'retake_enabled')::boolean then
      new.retakes := 0;
    end if;
  end if;

  -- Session date: "now" unless an earlier date was sent. A few minutes'
  -- leeway allows for a phone's clock being slightly ahead.
  if new.recorded_at is null then
    new.recorded_at := now();
  elsif new.recorded_at > now() + interval '5 minutes' then
    raise exception 'The session date can''t be in the future.';
  end if;

  new.recorded_by := coalesce(auth.uid(), new.recorded_by);
  return new;
end;
$$;

commit;

-- =====================================================================
-- AFTER check (runs automatically at the end of the file).
-- Expect every column on the right to be true, and the backed-up counts
-- to match the numbers from the before check.
-- =====================================================================
select
  exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'drill_entries' and column_name = 'time_seconds'
  ) as time_seconds_column,
  -- The app signs in as the "authenticated" role. These show it can
  -- read and add the new column (RLS then limits which rows).
  has_column_privilege('authenticated', 'public.drill_entries', 'time_seconds', 'SELECT') as app_can_read_time,
  has_column_privilege('authenticated', 'public.drill_entries', 'time_seconds', 'INSERT') as app_can_add_time,
  -- RLS is still switched on, and both drill_entries rules are still there.
  (select relrowsecurity from pg_class where oid = 'public.drill_entries'::regclass) as rls_still_on,
  (select count(*) = 2 from pg_policies where tablename = 'drill_entries') as both_rules_present,
  -- Every existing drill still passes the new settings check.
  (select bool_and(public.drill_config_is_valid(config)) is not false from public.drills) as existing_drills_valid,
  (select count(*) from backups.drills_2026_11_17) as drills_backed_up,
  (select count(*) from backups.drill_entries_2026_11_17) as drill_entries_backed_up;


-- =====================================================================
-- BEFORE check: copy ONLY the lines below into a NEW SQL Editor tab,
-- remove the "-- " at the start of each, and run. It changes nothing.
-- Note the two numbers.
-- =====================================================================
--
-- select
--   (select count(*) from public.drills) as drills,
--   (select count(*) from public.drill_entries) as drill_entries;
--
-- =====================================================================
-- UNDO (only if something went wrong, and before any timed drills are
-- used). Ask first: this puts the three functions back to their
-- previous versions, which are in 2026-11-12-drills.sql (drills_before_write
-- and drill_config_is_valid) and 2026-11-12-session-date-and-archive.sql
-- (drill_entries_before_insert). Re-run those "create or replace" blocks
-- after the lines below.
-- =====================================================================
--
-- begin;
-- delete from public.drill_entries where time_seconds is not null;
-- delete from public.drills where config->>'measure' = 'time';
-- alter table public.drill_entries drop column if exists time_seconds;
-- alter table public.drill_entries alter column total set not null;
-- alter table public.drill_entries alter column attempts drop default;
-- drop function if exists public.drill_time_level(numeric, jsonb);
-- commit;

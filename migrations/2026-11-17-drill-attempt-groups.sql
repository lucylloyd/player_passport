-- =====================================================================
-- Migration: attempt groups for drills, and one grouped kicking drill
-- Date: 2026-11-17
--
-- What this does, in plain language:
--   1. Backs up the drills and drill_entries tables.
--   2. Attempt groups: an attempts drill can now split its attempts into
--      named groups, e.g. Left × 5 then Right × 5. This is stored in the
--      drill's existing settings (drills.config):
--        "groups": [{"label": "Left", "attempts": 5}, {"label": "Right", "attempts": 5}]
--      "attempts" stays as the overall number (here 10), so everything
--      that already uses it keeps working. Drills without "groups" are
--      unchanged. Timed drills can't have groups.
--   3. drill_entries gets a new "group_totals" column. When a grouped
--      drill is saved, the database works out each group's subtotal
--      itself, e.g.
--        [{"label": "Left", "total": 12, "max": 15}, {"label": "Right", "total": 9, "max": 15}]
--      The overall total and level are still worked out from all the
--      attempts together, exactly as before, and still add one score.
--   4. Replaces the two ESM Goalies kicking drills with one grouped drill:
--        - "Movement into kicking LH" becomes "Movement into kicking"
--          with Left × 5 and Right × 5 (10 attempts, maximum 30 points),
--          result buttons Near baseline 3, Middle cones 2, Outer cones 1,
--          Behind line 0, and the same cut-offs (30 / 50 / 70 / 80).
--          Its quick tags and retake setting are kept.
--        - "Movement into kicking RH" is deleted.
--      Neither drill has any entries yet. The migration checks that
--      first and stops, changing nothing, if either has been run.
--
-- Security (RLS): no policy changes are needed. RLS rules decide which
-- ROWS someone can see or add, so the existing drill_entries rules
-- automatically cover group_totals. 2026-11-17-drill-attempt-groups-tests.sql
-- tests this as pretend coaches.
--
-- Run the whole file in one go in the Supabase SQL Editor. If any step
-- fails, nothing is changed. Then run the tests file.
--
-- BEFORE running, copy the "before" check at the bottom into a new tab.
-- =====================================================================

begin;

-- Safety check: stop if this migration has already been run.
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'drill_entries' and column_name = 'group_totals'
  ) then
    raise exception 'drill_entries.group_totals already exists, so this migration has already been run. Nothing was changed.';
  end if;
end $$;

-- Safety check: both kicking drills exist exactly once and have never
-- been run. Otherwise stop, so no results can be lost.
do $$
declare
  lh_count int;
  rh_count int;
begin
  select count(*) into lh_count
  from drills d join squads s on s.id = d.squad_id
  where s.name = 'ESM Goalies' and d.name = 'Movement into kicking LH';

  select count(*) into rh_count
  from drills d join squads s on s.id = d.squad_id
  where s.name = 'ESM Goalies' and d.name = 'Movement into kicking RH';

  if lh_count <> 1 or rh_count <> 1 then
    raise exception 'Expected one "Movement into kicking LH" and one "Movement into kicking RH" drill in ESM Goalies, but found % and %. Nothing was changed.', lh_count, rh_count;
  end if;

  if exists (
    select 1 from drill_entries e
    join drills d on d.id = e.drill_id
    join squads s on s.id = d.squad_id
    where s.name = 'ESM Goalies'
      and d.name in ('Movement into kicking LH', 'Movement into kicking RH')
  ) then
    raise exception 'One of the kicking drills has been run since this file was written, so it can''t be replaced safely. Nothing was changed.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Step 1: backups.
-- ---------------------------------------------------------------------
create schema if not exists backups;
create table backups.drills_groups_2026_11_17 as table public.drills;
alter table backups.drills_groups_2026_11_17 enable row level security;
create table backups.drill_entries_groups_2026_11_17 as table public.drill_entries;
alter table backups.drill_entries_groups_2026_11_17 enable row level security;

-- ---------------------------------------------------------------------
-- Step 2: the new column for group subtotals. Empty for drills
-- without groups, and for timed drills.
-- ---------------------------------------------------------------------
alter table public.drill_entries
  add column group_totals jsonb;

-- ---------------------------------------------------------------------
-- Step 3: the settings check now understands groups. Everything else
-- is unchanged from 2026-11-17-timed-drills.sql.
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
    if c ? 'groups' then return false; end if;  -- timed drills have no groups
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

  -- ---- Attempt drills ----
  prev := 0;

  -- attempts: whole number from 1 to 50
  if jsonb_typeof(c->'attempts') is distinct from 'number' then return false; end if;
  if (c->>'attempts')::numeric not between 1 and 50
     or (c->>'attempts')::numeric <> trunc((c->>'attempts')::numeric) then return false; end if;

  -- groups (optional, new): 2 to 6 groups, each with a label and a whole
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
-- Step 4: the drill-entry check now also works out group subtotals.
-- Attempts are in order: with Left × 5, Right × 5, attempts 1–5 are
-- Left and 6–10 are Right. Everything else is unchanged from
-- 2026-11-17-timed-drills.sql.
-- ---------------------------------------------------------------------
create or replace function public.drill_entries_before_insert()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  d record;
  max_total numeric;
  top_points numeric;
  g jsonb;
  n int;
  pos int;
  sub int;
  totals jsonb;
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
    new.group_totals := null;
    new.level := drill_time_level(new.time_seconds, d.config->'time_cutoffs');
  else
    -- ---- Attempt drill ----
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

    select max((r->>'points')::numeric) into top_points
    from jsonb_array_elements(d.config->'results') r;
    max_total := top_points * (d.config->>'attempts')::numeric;

    select coalesce(sum((a #>> '{}')::numeric), 0)::int
      into new.total
    from jsonb_array_elements(new.attempts) a;

    new.level := drill_level(new.total, max_total, d.config->'cutoffs');

    -- Group subtotals (new). Whatever the app sent is replaced.
    if jsonb_typeof(d.config->'groups') = 'array' then
      totals := '[]'::jsonb;
      pos := 0;
      for g in select * from jsonb_array_elements(d.config->'groups') loop
        n := (g->>'attempts')::int;
        select coalesce(sum((a.value #>> '{}')::numeric), 0)::int into sub
        from jsonb_array_elements(new.attempts) with ordinality as a(value, idx)
        where a.idx > pos and a.idx <= pos + n;
        totals := totals || jsonb_build_array(jsonb_build_object(
          'label', g->>'label', 'total', sub, 'max', (top_points * n)::int));
        pos := pos + n;
      end loop;
      new.group_totals := totals;
    else
      new.group_totals := null;
    end if;

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

-- ---------------------------------------------------------------------
-- Step 5: one grouped kicking drill in place of LH and RH.
-- "||" merges the new settings into the old ones, so LH's quick tags
-- and retake setting are kept.
-- ---------------------------------------------------------------------
update public.drills d
set name = 'Movement into kicking',
    config = d.config || '{
      "measure": "attempts",
      "attempts": 10,
      "groups": [{"label": "Left", "attempts": 5}, {"label": "Right", "attempts": 5}],
      "results": [
        {"label": "Near baseline", "points": 3},
        {"label": "Middle cones", "points": 2},
        {"label": "Outer cones", "points": 1},
        {"label": "Behind line", "points": 0}
      ],
      "cutoffs": [30, 50, 70, 80]
    }'::jsonb
from public.squads s
where s.id = d.squad_id
  and s.name = 'ESM Goalies'
  and d.name = 'Movement into kicking LH';

delete from public.drills d
using public.squads s
where s.id = d.squad_id
  and s.name = 'ESM Goalies'
  and d.name = 'Movement into kicking RH';

commit;

-- =====================================================================
-- AFTER check (runs automatically at the end of the file).
-- Expect: every true/false column true, kicking_drills = 1, and the
-- backed-up counts matching the numbers from the before check.
-- =====================================================================
select
  exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'drill_entries' and column_name = 'group_totals'
  ) as group_totals_column,
  has_column_privilege('authenticated', 'public.drill_entries', 'group_totals', 'SELECT') as app_can_read_groups,
  (select relrowsecurity from pg_class where oid = 'public.drill_entries'::regclass) as rls_still_on,
  (select count(*) = 2 from pg_policies where tablename = 'drill_entries') as both_rules_present,
  (select bool_and(public.drill_config_is_valid(config)) is not false from public.drills) as existing_drills_valid,
  (select count(*) from public.drills d join public.squads s on s.id = d.squad_id
   where s.name = 'ESM Goalies' and d.name like 'Movement into kicking%') as kicking_drills,
  (select config->'groups' is not null from public.drills d join public.squads s on s.id = d.squad_id
   where s.name = 'ESM Goalies' and d.name = 'Movement into kicking') as kicking_drill_grouped,
  (select count(*) from backups.drills_groups_2026_11_17) as drills_backed_up,
  (select count(*) from backups.drill_entries_groups_2026_11_17) as drill_entries_backed_up;


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
-- UNDO (only if something went wrong, and before the grouped kicking
-- drill is used). Ask first: this also needs drill_config_is_valid and
-- drill_entries_before_insert putting back to their versions in
-- 2026-11-17-timed-drills.sql, by re-running those blocks afterwards.
-- =====================================================================
--
-- This puts the two kicking drills back from the backup and removes
-- the new column:
--
-- begin;
-- delete from public.drills where id in (
--   select id from backups.drills_groups_2026_11_17
--   where name in ('Movement into kicking LH', 'Movement into kicking RH'));
-- insert into public.drills
--   select * from backups.drills_groups_2026_11_17
--   where name in ('Movement into kicking LH', 'Movement into kicking RH');
-- alter table public.drill_entries drop column if exists group_totals;
-- commit;

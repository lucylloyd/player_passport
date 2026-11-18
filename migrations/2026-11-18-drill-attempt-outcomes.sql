-- =====================================================================
-- Migration: save the outcome name of every drill attempt
-- Date: 2026-11-18
--
-- Why: until now each run saved only the POINTS of each attempt, e.g.
-- [4, 3, 2, 4, 1]. If a drill's scoring changed later (say Post went
-- from 3 to 4 points), old runs couldn't be re-scored, because a saved
-- "4" wouldn't say whether it was a goal or a post. Saving the outcome
-- name too, e.g. ["Goal", "Post", "Wide", "Goal", "Esther"], means any
-- past run can be re-scored exactly if the scoring changes.
--
-- What this does, in plain language:
--   1. Backs up the drill_entries table.
--   2. Adds an "attempt_labels" column to drill_entries: the outcome
--      name of each attempt, in the same order as the points.
--   3. When a run is saved, the database:
--        - checks each outcome name is one of the drill's result buttons
--          AND matches that attempt's points (so the two can't disagree),
--        - or, if no names are sent (e.g. an older copy of the app),
--          fills them in from the points where that's unambiguous.
--      Timed drills have no attempts, so they have no names.
--      Everything else about saving a run is unchanged from
--      2026-11-17-drill-attempt-groups.sql.
--   4. Fills in the names for runs already saved, from their points and
--      the drill's current buttons. A position is left empty only if two
--      buttons share the same points (then the name can't be known).
--
-- Security (RLS): no policy changes are needed. RLS works on whole rows,
-- so the existing drill_entries rules cover the new column.
-- 2026-11-18-drill-attempt-outcomes-tests.sql tests it as pretend coaches.
--
-- Run the whole file in one go in the Supabase SQL Editor. If Supabase
-- asks about RLS, choose plain "Run". Then run the tests file.
-- Run this BEFORE merging the app change.
-- =====================================================================

begin;

-- Safety check: stop if this migration has already been run.
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'drill_entries' and column_name = 'attempt_labels'
  ) then
    raise exception 'drill_entries.attempt_labels already exists, so this migration has already been run. Nothing was changed.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Step 1: backup.
-- ---------------------------------------------------------------------
create schema if not exists backups;
create table backups.drill_entries_outcomes_2026_11_18 as table public.drill_entries;
alter table backups.drill_entries_outcomes_2026_11_18 enable row level security;

-- ---------------------------------------------------------------------
-- Step 2: the new column.
-- ---------------------------------------------------------------------
alter table public.drill_entries
  add column attempt_labels jsonb;

-- Helper: the outcome names for a list of points, using a drill's
-- result buttons. A position is null if no button, or more than one
-- button, has those points.
create function public.drill_labels_from_points(attempts jsonb, results jsonb)
returns jsonb
language sql
immutable
set search_path = public
as $$
  select coalesce(jsonb_agg(
    (select case when count(*) = 1 then to_jsonb(min(r->>'label')) else 'null'::jsonb end
     from jsonb_array_elements(results) r
     where (r->>'points')::numeric = (a.pts #>> '{}')::numeric)
    order by a.i), '[]'::jsonb)
  from jsonb_array_elements(attempts) with ordinality as a(pts, i);
$$;

-- ---------------------------------------------------------------------
-- Step 3: the drill-entry check now also handles outcome names.
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
    new.attempt_labels := null;
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

    -- Outcome names (new): check the ones sent, or fill them in.
    if new.attempt_labels is not null then
      if jsonb_typeof(new.attempt_labels) is distinct from 'array'
         or jsonb_array_length(new.attempt_labels) <> jsonb_array_length(new.attempts) then
        raise exception 'There must be one outcome name for each attempt.';
      end if;
      if exists (
        select 1
        from jsonb_array_elements(new.attempt_labels) with ordinality as l(lab, i)
        join jsonb_array_elements(new.attempts) with ordinality as a(pts, j) on l.i = a.j
        where jsonb_typeof(l.lab) <> 'string'
           or not exists (
             select 1 from jsonb_array_elements(d.config->'results') r
             where r->>'label' = l.lab #>> '{}'
               and (r->>'points')::numeric = (a.pts #>> '{}')::numeric
           )
      ) then
        raise exception 'Each attempt''s outcome must be one of the drill''s result buttons, with matching points.';
      end if;
    else
      new.attempt_labels := drill_labels_from_points(new.attempts, d.config->'results');
    end if;

    select max((r->>'points')::numeric) into top_points
    from jsonb_array_elements(d.config->'results') r;
    max_total := top_points * (d.config->>'attempts')::numeric;

    select coalesce(sum((a #>> '{}')::numeric), 0)::int
      into new.total
    from jsonb_array_elements(new.attempts) a;

    new.level := drill_level(new.total, max_total, d.config->'cutoffs');

    -- Group subtotals. Whatever the app sent is replaced.
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
-- Step 4: fill in names for runs already saved (attempt drills only).
-- ---------------------------------------------------------------------
update public.drill_entries e
set attempt_labels = public.drill_labels_from_points(e.attempts, d.config->'results')
from public.drills d
where d.id = e.drill_id
  and coalesce(d.config->>'measure', 'attempts') <> 'time'
  and jsonb_array_length(e.attempts) > 0;

commit;

-- =====================================================================
-- AFTER check (runs automatically at the end of the file).
-- Expect: every true/false column true, attempt_runs_missing_names = 0
-- (unless a drill has two buttons with the same points), and the
-- backed-up count matching your number of drill entries.
-- =====================================================================
select
  exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'drill_entries' and column_name = 'attempt_labels'
  ) as attempt_labels_column,
  has_column_privilege('authenticated', 'public.drill_entries', 'attempt_labels', 'SELECT') as app_can_read_names,
  has_column_privilege('authenticated', 'public.drill_entries', 'attempt_labels', 'INSERT') as app_can_add_names,
  (select relrowsecurity from pg_class where oid = 'public.drill_entries'::regclass) as rls_still_on,
  (select count(*) = 2 from pg_policies where tablename = 'drill_entries') as both_rules_present,
  (select count(*) from public.drill_entries
   where jsonb_array_length(attempts) > 0
     and (attempt_labels is null or attempt_labels @> '[null]'::jsonb)) as attempt_runs_missing_names,
  (select count(*) from backups.drill_entries_outcomes_2026_11_18) as drill_entries_backed_up;

-- =====================================================================
-- UNDO (only if something went wrong). Ask first: this also needs
-- drill_entries_before_insert putting back to its version in
-- 2026-11-17-drill-attempt-groups.sql, by re-running that block after
-- the lines below. Merge nothing until the undo is complete.
-- =====================================================================
--
-- begin;
-- alter table public.drill_entries drop column if exists attempt_labels;
-- drop function if exists public.drill_labels_from_points(jsonb, jsonb);
-- commit;

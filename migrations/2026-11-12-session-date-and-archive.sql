-- =====================================================================
-- Migration: drill session dates, and archiving attributes
-- Date: 2026-11-12
--
-- What this does, in plain language:
--   1. Backs up the attributes and scores tables.
--   2. Session date: a drill entry can now be saved with an earlier
--      date (e.g. a session recorded on paper last week). The date is
--      kept on the entry AND on the score it creates, so the player's
--      history shows the real session date. Dates in the future are
--      rejected.
--   3. Archiving: adds an "archived_at" column to attributes. An
--      archived attribute is hidden in the app, but none of its scores
--      are touched. Archiving is undone by clearing the date.
--      Admins can now archive and restore attributes from the app
--      (a new rule lets admins update attributes; coaches still can't).
--      Drills can't be run on an archived attribute.
--   4. Safer deletes: scores → attributes changes from ON DELETE
--      CASCADE (deleting an attribute silently deleted all its scores)
--      to ON DELETE RESTRICT (deleting an attribute that has scores is
--      refused). The scores table is backed up first.
--
-- Run the whole file in one go in the Supabase SQL Editor. If any step
-- fails, nothing is changed.
--
-- BEFORE running, copy the "before" check at the bottom into a new tab.
-- =====================================================================

begin;

-- Safety check: stop if this migration has already been run.
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'attributes' and column_name = 'archived_at'
  ) then
    raise exception 'attributes.archived_at already exists, so this migration has already been run. Nothing was changed.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Step 1: backups.
-- ---------------------------------------------------------------------
create schema if not exists backups;
create table backups.attributes_2026_11_12 as table public.attributes;
alter table backups.attributes_2026_11_12 enable row level security;
create table backups.scores_before_restrict_2026_11_12 as table public.scores;
alter table backups.scores_before_restrict_2026_11_12 enable row level security;

-- ---------------------------------------------------------------------
-- Step 1b: deleting an attribute that has scores is now refused,
-- instead of silently deleting those scores. (The rule's old name
-- "scores_skill_id_fkey" is kept; it dates from when the column was
-- called skill_id.)
-- ---------------------------------------------------------------------
alter table public.scores drop constraint scores_skill_id_fkey;
alter table public.scores
  add constraint scores_skill_id_fkey
  foreign key (attribute_id) references public.attributes(id) on delete restrict;

-- ---------------------------------------------------------------------
-- Step 2: archiving attributes.
-- Empty (null) = active. A date = archived on that date.
-- ---------------------------------------------------------------------
alter table public.attributes
  add column archived_at timestamptz;

-- Admins can update attributes (used by the app's Archive/Restore).
create policy "attributes: admin can update" on public.attributes
  for update using (is_admin()) with check (is_admin());

-- ---------------------------------------------------------------------
-- Step 3: replace the drill-entry check so it:
--   - accepts an earlier session date in recorded_at (but not a
--     future one); if none is sent, it's "now", as before
--   - refuses entries for an archived attribute
-- Everything else is unchanged from 2026-11-12-drills.sql.
-- The existing after-insert step already copies recorded_at into the
-- score's scored_at, so the score gets the same date.
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
-- Expect: archived_at_column = true, archived_attributes = 0,
-- admin_update_rule = true, scores_delete_rule ending in
-- "ON DELETE RESTRICT", and the two backed-up counts matching the
-- numbers from the before check.
-- =====================================================================
select
  (select pg_get_constraintdef(oid) from pg_constraint
   where conname = 'scores_skill_id_fkey') as scores_delete_rule,
  (select count(*) from backups.scores_before_restrict_2026_11_12) as scores_backed_up,
  exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'attributes' and column_name = 'archived_at'
  ) as archived_at_column,
  (select count(*) from public.attributes where archived_at is not null) as archived_attributes,
  exists (
    select 1 from pg_policies
    where tablename = 'attributes' and policyname = 'attributes: admin can update'
  ) as admin_update_rule,
  (select count(*) from backups.attributes_2026_11_12) as attributes_backed_up;


-- =====================================================================
-- BEFORE check: copy ONLY the lines below into a NEW SQL Editor tab,
-- remove the "-- " at the start of each, and run. It changes nothing.
-- Note the number of attributes.
-- =====================================================================
--
-- select
--   (select count(*) from public.attributes) as attributes,
--   (select count(*) from public.scores) as scores;
--
-- =====================================================================
-- UNDO (only if something went wrong). Ask first: the drill-entry
-- check above uses archived_at, so after this undo it also needs
-- putting back to its 2026-11-12-drills.sql version, or saving drill
-- results will fail.
-- =====================================================================
--
-- begin;
-- alter table public.scores drop constraint scores_skill_id_fkey;
-- alter table public.scores add constraint scores_skill_id_fkey
--   foreign key (attribute_id) references public.attributes(id) on delete cascade;
-- drop policy if exists "attributes: admin can update" on public.attributes;
-- alter table public.attributes drop column if exists archived_at;
-- commit;

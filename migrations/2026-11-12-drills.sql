-- =====================================================================
-- Migration: drills
-- Date: 2026-11-12
--
-- What this does, in plain language:
--   1. Backs up coach_squads (the only existing table this changes).
--   2. Adds a yes/no "is_lead" column to coach_squads. A coach marked
--      as lead for a squad can set up drills for that squad.
--   3. Creates the "drills" table: a structured test for one attribute
--      (e.g. 5 attempts at a push pass, each scored Hit/Close/Miss).
--      A drill belongs to the squad of its attribute; the database
--      fills that in automatically.
--   4. Creates the "drill_entries" table: one row each time a coach
--      runs a drill with a player.
--   5. When an entry is saved, the database itself:
--        - checks the player is in the drill's squad,
--        - checks every attempt is one of the drill's result options,
--        - works out the total and the level (1–5),
--        - adds a matching row to "scores", so the existing screens
--          show the new level straight away.
--   6. Security rules (RLS):
--        - drills: coaches see their squads' drills; admins and squad
--          leads create and edit them; only admins delete them.
--        - drill_entries: coaches see and add entries only for players
--          in squads they're allocated to. Entries can't be edited or
--          deleted from the app, the same as scores.
--
-- Run the whole file in one go in the Supabase SQL Editor. If any step
-- fails, nothing is changed. Then run 2026-11-12-drills-tests.sql.
--
-- BEFORE running, copy the "before" check at the bottom of this file
-- into a new SQL Editor tab and run it.
-- =====================================================================

begin;

-- Safety check: stop if this migration has already been run.
do $$
begin
  if to_regclass('public.drills') is not null then
    raise exception 'The drills table already exists, so this migration has already been run. Nothing was changed.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Step 1: backup of the table this migration changes.
-- ---------------------------------------------------------------------
create schema if not exists backups;
create table backups.coach_squads_2026_11_12 as table public.coach_squads;
alter table backups.coach_squads_2026_11_12 enable row level security;

-- ---------------------------------------------------------------------
-- Step 2: squad leads.
-- Everyone starts as not-a-lead. Only admins can change this (the
-- existing "coach_squads: admin can manage" policy already covers it).
-- ---------------------------------------------------------------------
alter table public.coach_squads
  add column is_lead boolean not null default false;

-- ---------------------------------------------------------------------
-- Step 3: helper functions used by the tables below.
-- ---------------------------------------------------------------------

-- Checks a drill's settings are complete and sensible. Expected shape:
-- {
--   "attempts": 5,
--   "results": [{"label": "Hit", "points": 2}, {"label": "Miss", "points": 0}],
--   "retake_enabled": true,
--   "retake_label": "Retake",
--   "tags": ["Weak side"],
--   "cutoffs": [40, 60, 75, 90]
-- }
-- "cutoffs" are the minimum percentage of the maximum score needed for
-- levels 2, 3, 4 and 5. Below the first cut-off is level 1.
create function public.drill_config_is_valid(c jsonb)
returns boolean
language plpgsql
immutable
set search_path = public
as $$
declare
  prev numeric := 0;
  x jsonb;
begin
  if jsonb_typeof(c) is distinct from 'object' then return false; end if;

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

  -- quick tags: a list of text
  if jsonb_typeof(c->'tags') is distinct from 'array' then return false; end if;
  if exists (select 1 from jsonb_array_elements(c->'tags') t where jsonb_typeof(t) <> 'string') then return false; end if;

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

-- Works out the level (1–5) from a total, the maximum possible total
-- and the cut-offs. Uses whole-number maths so 40% is exactly 40%.
-- The app uses the same rule (drillLevel in index.html).
create function public.drill_level(total numeric, max_total numeric, cutoffs jsonb)
returns int
language sql
immutable
set search_path = public
as $$
  select case
    when max_total <= 0 then 1
    else 1 + (select count(*)::int
              from jsonb_array_elements(cutoffs) c
              where total * 100 >= (c #>> '{}')::numeric * max_total)
  end;
$$;

-- ---------------------------------------------------------------------
-- Step 4: the drills table.
-- ---------------------------------------------------------------------
create table public.drills (
  id           uuid primary key default gen_random_uuid(),
  squad_id     uuid not null references public.squads(id) on delete cascade,
  name         text not null check (length(trim(name)) > 0),
  attribute_id uuid not null references public.attributes(id) on delete cascade,
  config       jsonb not null default '{
    "attempts": 5,
    "results": [{"label": "Hit", "points": 2}, {"label": "Partial", "points": 1}, {"label": "Miss", "points": 0}],
    "retake_enabled": true,
    "retake_label": "Retake",
    "tags": [],
    "cutoffs": [40, 60, 75, 90]
  }'::jsonb,
  created_by   uuid default auth.uid(),
  created_at   timestamptz not null default now(),
  constraint drills_config_valid check (public.drill_config_is_valid(config))
);
create index drills_squad_id_idx on public.drills (squad_id);
create index drills_attribute_id_idx on public.drills (attribute_id);

-- Fills in squad_id from the attribute, so a drill always belongs to
-- its attribute's squad. Also stops the attribute being swapped once
-- the drill has been used, so old entries stay linked to the right
-- attribute.
create function public.drills_before_write()
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
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- Step 5: the drill_entries table.
-- ---------------------------------------------------------------------
create table public.drill_entries (
  id          uuid primary key default gen_random_uuid(),
  drill_id    uuid not null references public.drills(id) on delete restrict,
  player_id   uuid not null references public.players(id) on delete cascade,
  attempts    jsonb not null,
  retakes     int not null default 0 check (retakes >= 0),
  tags        text[] not null default '{}',
  note        text,
  total       int not null,
  level       int not null check (level between 1 and 5),
  recorded_by uuid default auth.uid(),
  recorded_at timestamptz not null default now()
);
create index drill_entries_player_id_idx on public.drill_entries (player_id);
create index drill_entries_drill_id_idx on public.drill_entries (drill_id);

-- Before an entry is saved: check it, and work out the total and level.
-- Whatever total/level the app sends is replaced by this calculation.
create function public.drill_entries_before_insert()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  d record;
  max_total numeric;
begin
  select dr.squad_id, dr.config into d
  from drills dr
  where dr.id = new.drill_id;

  if not found then
    raise exception 'That drill could not be found.';
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

  new.recorded_by := coalesce(auth.uid(), new.recorded_by);
  new.recorded_at := now();
  return new;
end;
$$;

-- After an entry is saved: add the matching score, so the player's
-- passport shows the new level. This runs with the coach's own rights,
-- so the existing scores rules still apply.
create function public.drill_entries_after_insert()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  insert into scores (player_id, attribute_id, value, scored_by, scored_at)
  select new.player_id, dr.attribute_id, new.level, new.recorded_by, new.recorded_at
  from drills dr
  where dr.id = new.drill_id;
  return new;
end;
$$;

create trigger drills_before_write
  before insert or update on public.drills
  for each row execute function public.drills_before_write();

create trigger drill_entries_before_insert
  before insert on public.drill_entries
  for each row execute function public.drill_entries_before_insert();

create trigger drill_entries_after_insert
  after insert on public.drill_entries
  for each row execute function public.drill_entries_after_insert();

-- ---------------------------------------------------------------------
-- Step 6: security rules (RLS), following the existing pattern.
-- ---------------------------------------------------------------------
alter table public.drills enable row level security;

create policy "drills: coach sees own squads" on public.drills
  for select using (
    is_admin() or squad_id in (
      select squad_id from coach_squads where coach_id = auth.uid()
    )
  );

create policy "drills: admin or squad lead can create" on public.drills
  for insert with check (
    is_admin() or squad_id in (
      select squad_id from coach_squads where coach_id = auth.uid() and is_lead
    )
  );

create policy "drills: admin or squad lead can edit" on public.drills
  for update using (
    is_admin() or squad_id in (
      select squad_id from coach_squads where coach_id = auth.uid() and is_lead
    )
  ) with check (
    is_admin() or squad_id in (
      select squad_id from coach_squads where coach_id = auth.uid() and is_lead
    )
  );

create policy "drills: admin can delete" on public.drills
  for delete using (is_admin());

alter table public.drill_entries enable row level security;

create policy "drill_entries: coach sees own squads" on public.drill_entries
  for select using (
    is_admin() or player_id in (
      select p.id from players p
      where p.squad_id in (
        select squad_id from coach_squads where coach_id = auth.uid()
      )
    )
  );

create policy "drill_entries: coach can insert for own squads" on public.drill_entries
  for insert with check (
    is_admin() or player_id in (
      select p.id from players p
      where p.squad_id in (
        select squad_id from coach_squads where coach_id = auth.uid()
      )
    )
  );

commit;

-- =====================================================================
-- AFTER check (runs automatically at the end of the file).
-- Expect 4 rows: both new tables with RLS on, plus the new column.
-- =====================================================================
select 'drills' as item, relrowsecurity as rls_enabled
from pg_class where oid = 'public.drills'::regclass
union all
select 'drill_entries', relrowsecurity
from pg_class where oid = 'public.drill_entries'::regclass
union all
select 'coach_squads.is_lead column', true
from information_schema.columns
where table_schema = 'public' and table_name = 'coach_squads' and column_name = 'is_lead'
union all
select 'coach_squads rows backed up: ' || count(*), true
from backups.coach_squads_2026_11_12;


-- =====================================================================
-- BEFORE check: copy into a NEW SQL Editor tab and run first.
-- It changes nothing. Expect "drills_table_exists = false" and a count
-- of your coach-to-squad links (compare with the after check).
-- =====================================================================
--
-- select
--   to_regclass('public.drills') is not null as drills_table_exists,
--   (select count(*) from public.coach_squads) as coach_squad_links;
--
-- =====================================================================
-- MAKING SOMEONE A SQUAD LEAD (after the migration):
-- =====================================================================
--
-- update coach_squads cs
-- set is_lead = true
-- from auth.users u, squads s
-- where cs.coach_id = u.id and cs.squad_id = s.id
--   and u.email = 'coach@example.com'
--   and s.name  = 'ESMU16';
--
-- =====================================================================
-- UNDO (only if something went wrong, and before any real drills are
-- used): copy into a new tab and run. This removes drills and entries,
-- but NOT the scores that entries created.
-- =====================================================================
--
-- begin;
-- drop table if exists public.drill_entries;
-- drop table if exists public.drills;
-- drop function if exists public.drill_entries_after_insert();
-- drop function if exists public.drill_entries_before_insert();
-- drop function if exists public.drills_before_write();
-- drop function if exists public.drill_level(numeric, numeric, jsonb);
-- drop function if exists public.drill_config_is_valid(jsonb);
-- alter table public.coach_squads drop column if exists is_lead;
-- commit;

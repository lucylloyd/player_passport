# Player Passport (Progress Squad)

A web app that grassroots sports coaches use to score youth players against benchmarked attributes and leave feedback. Coaches sign in and only see the squads they've been allocated to.

The owner (Lucy) is learning as she goes. Read **Working rules** before making any change.

## Working rules

1. **Always work on a new git branch, never directly on `main`.** Create the branch from the latest `origin/main` before editing anything. `main` is what GitHub Pages serves, so anything merged there goes live.
2. **Explain changes in plain language.** Say what changed, why, and what Lucy will see differently. Avoid jargon, or explain it when it can't be avoided.
3. **Database changes go in a SQL file in `/migrations`, for Lucy to review and run herself** in the Supabase SQL Editor. Never run database changes directly.
   - Name files `migrations/YYYY-MM-DD-short-description.sql`.
   - Every file **starts with a backup of each table it affects** (see the template below).
   - Add comments in the file explaining each step in plain language, plus a check query at the end so Lucy can confirm it worked.
   - Wrap the changes in `begin; … commit;` so a failure changes nothing.
4. **Every new table must have RLS enabled**, with policies that follow the existing pattern: coaches only reach squads they're allocated to through `coach_squads`, and admins (`is_admin()`) reach everything. See the template below.
5. **Never put the `service_role` key in the frontend**, or anywhere in this repo. It bypasses all RLS. Only the publishable (anon) key belongs in `index.html`.
6. **Test changes with `?preview=1` and fake data before Lucy deploys.** Preview mode needs no sign-in and never touches Supabase. If a change adds new data or fields, update the preview mock data too so it can be tested.

## Architecture

- **The whole app is one HTML file: `index.html`.** There is no build step and no `package.json`.
  - React, ReactDOM and supabase-js are pasted into the file as minified `<script>` blocks. They are at the top, before about line 363. Don't edit them.
  - The app code is in the last `<script>` block. It's already compiled from JSX, so it's written as `React.createElement(...)` calls, not JSX tags. Edit it in that same style.
- **Supabase** provides the database (Postgres), sign-in and row-level security (RLS).
  - The project URL and the publishable key are set near the top of the app script (`SUPABASE_URL`, `SUPABASE_ANON_KEY`). It's safe for the publishable key to be public, because RLS controls what it can reach.
  - Coaches sign in with an emailed magic link or a 6-digit code (`signInWithOtp` with `shouldCreateUser: false`, then `verifyOtp`). Nobody can sign up themselves: an admin invites each coach in Supabase, under Authentication → Users.
  - Emails are sent through custom SMTP set up in Supabase.
- **Hosting**: GitHub Pages serves the `main` branch at **app.progresssquad.co.uk**, set by the `CNAME` file.
- **Preview mode**: `?preview=1` (`isPreviewMode`) skips sign-in and loads a built-in demo squad, `PREVIEW_SQUAD`, `PREVIEW_ATTRIBUTES` and `makePreviewPlayers()`. Edits in preview mode are only kept in memory.
- **Other files**
  - `privacy/index.html` and `privacyPP.md`: the public privacy page.
  - `docs/schema.md`: a dump of the database columns and RLS policies. Update it after any migration.
  - `PPwithattributedescription.html` and `player-passport(3).html`: older copies of the app. They aren't served as the app, so don't edit them.

## How the app reads and writes data

- On load, the app selects **all** `players` (with `squads(id, name)`), and then the `attributes` for those squads. After that it loads `scores` and `feedback` for those players. It doesn't filter by coach: **RLS does the filtering**, so a coach only gets back the players in their squads.
- Each time a coach saves a score, the app **inserts a new row**. It never updates the old one. The latest row per player and attribute is the current score, and earlier rows are the history.
- Feedback is linked to a **player**, not to an attribute.

## Scoring scale and categories

- Every attribute is scored on one 5-level scale: 1 Not yet, 2 Developing, 3 Secure, 4 Strong, 5 Excellent. The database rejects any other value (see `scores` below).
- The level names are set in one place, `SCORE_LEVEL_LABELS`. Colours are in `SCORE_SCALE`. Each level has a `color` (badge and bar) and a `text` colour chosen for at least 4.5:1 contrast, so check contrast if you change a colour.
- An older 3-level "outcomes" scale and an "Outcomes" category were removed on 2026-11-12. They were only ever used in the demo data.
- Attribute categories must be one of `attitude`, `tactical`, `technical` or `physical`, in lowercase (`CATEGORY_ORDER`). **An attribute with any other category won't appear in the app.** If it has no category, it shows under Attitude.

## Drills

- A drill is a structured test that produces a 1–5 score for **one attribute**. Because attributes belong to one squad, so does each drill: `drills.squad_id` is filled in by the database from the attribute.
- `drills.config` (jsonb) holds `attempts`, `results` (`[{label, points}]`), `retake_enabled`, `retake_label`, `tags` and `cutoffs`. `cutoffs` holds 4 whole percentages of the maximum total, the minimum for levels 2–5; the default is `[40, 60, 75, 90]`. The database checks this shape with `drill_config_is_valid()`, and the app mirrors it in `drillProblems()`.
- Level = 1 + the number of cut-offs where `total × 100 ≥ cutoff × max`. This whole-number rule is in both `drill_level()` (SQL) and `drillLevel()` (app). Keep them the same.
- When a `drill_entries` row is inserted, triggers check it, **recalculate `total` and `level`** (ignoring what the app sent), and insert the matching `scores` row. The app only inserts `drill_id`, `player_id`, `attempts`, `retakes`, `tags` and `note`.
- Once a drill has entries, its attribute can't be changed, and it can't be deleted (`on delete restrict`). Deleting an attribute that has drill entries is therefore blocked too.
- Screens: "Drill setup" (`DrillSetup` and `DrillEditor`), shown to admins and squad leads, and "Run drill" on a player's page (`DrillRunner`).
- Not built yet: attempt groups and timed drills.
- To make a coach a squad lead, set `coach_squads.is_lead = true` for that coach and squad in the SQL Editor. Only admins can change it.

## Database tables

All tables are in the `public` schema, and all IDs are `uuid`.

| Table | Columns | Notes |
|---|---|---|
| `squads` | `id`, `name` | |
| `attributes` | `id`, `squad_id`, `name`, `category`, `sort_order`, `description`, `sport` | Each squad has its own copy of each attribute, so the same name in two squads means two different rows. `sort_order` sets the display order. `description` is the scoring criteria coaches see when they tap an attribute. |
| `players` | `id`, `name`, `age`, `squad_id`, `position`, `role` | `position` and `role` are free text, shown as tags on the player tile. |
| `scores` | `id`, `player_id`, `attribute_id`, `value` (int), `scored_by` (coach uuid), `scored_at` | Only new rows are added; old scores aren't changed. `value` must be 1–5, enforced by the check constraint `scores_value_1_to_5`. |
| `feedback` | `id`, `player_id`, `note`, `coach_id`, `created_at` | |
| `coach_squads` | `coach_id`, `squad_id`, `is_lead` | Links coaches (`auth.users.id`) to squads. **This table controls who sees what.** `is_lead` lets that coach set up drills for that squad. |
| `drills` | `id`, `squad_id`, `name`, `attribute_id`, `config` (jsonb), `created_by`, `created_at` | See **Drills** above. |
| `drill_entries` | `id`, `drill_id`, `player_id`, `attempts` (jsonb list of points), `retakes`, `tags` (text[]), `note`, `total`, `level`, `recorded_by`, `recorded_at` | Like `scores`, only new rows are added. Each one also adds a `scores` row. |
| `profiles` | `id`, `email`, `role` | One row per user. A user is an admin when `role = 'admin'`. |

## RLS policies

The pattern used throughout: **`is_admin()` OR the row belongs to a squad listed in `coach_squads` for `auth.uid()`**.

`is_admin()` is a `security definer` SQL function: `select exists (select 1 from profiles where id = auth.uid() and role = 'admin')`. To make someone an admin, set their `profiles.role` to `'admin'` in the SQL Editor. Coaches can't change their own role, because `profiles` has no UPDATE policy.

| Table | Command | Who |
|---|---|---|
| `squads` | SELECT | Any signed-in user. |
| `attributes` | SELECT | Any signed-in user. |
| `players` | SELECT | Admin, or a coach of the player's squad. |
| `players` | INSERT / UPDATE / DELETE | Admin only. |
| `scores` | SELECT, INSERT | Admin, or a coach of the player's squad. |
| `feedback` | SELECT, INSERT | Admin, or a coach of the player's squad. |
| `coach_squads` | SELECT | The coach themselves, or an admin. |
| `coach_squads` | ALL | Admin only. |
| `profiles` | SELECT | The user themselves, or an admin. |
| `drills` | SELECT | Admin, or a coach of the drill's squad. |
| `drills` | INSERT / UPDATE | Admin, or a lead (`is_lead`) of the drill's squad. |
| `drills` | DELETE | Admin only. |
| `drill_entries` | SELECT, INSERT | Admin, or a coach of the player's squad. |

RLS tests for drills are in `migrations/2026-11-12-drills-tests.sql`. They act as pretend coaches by running `set local role authenticated` and setting `request.jwt.claims`, then stop on purpose so nothing is kept. Follow the same pattern for future security tests.

Gaps to be aware of:
- Nobody, including admins, can update or delete `scores` or `feedback` from the app. Changes to these tables are made in the SQL Editor.
- `squads` and `attributes` have no write policies, so they're managed in the SQL Editor.
- Any signed-in coach can read every squad name and attribute, but no player data outside their own squads.

The SQL Editor runs with full rights and ignores RLS. It's where admin changes such as adding squads, players and coach links are made.

## Templates

### Backup at the start of a migration

Backups go in a separate `backups` schema, not `public`. That way they aren't reachable through the app's API, which only exposes `public`. RLS is also enabled on each backup, with no policies. This means nobody can read it through the API even if the schema is exposed by mistake. It also stops the Supabase SQL Editor from warning about a table without RLS. The SQL Editor still reads backups normally, because it runs as the table owner.

Name each backup `<table>_<YYYY_MM_DD>` after the migration date.

```sql
create schema if not exists backups;
create table backups.scores_YYYY_MM_DD as table public.scores;
alter table backups.scores_YYYY_MM_DD enable row level security;
-- repeat both lines for each table this migration changes
```

To restore a table from a backup:

```sql
truncate public.scores;
insert into public.scores select * from backups.scores_YYYY_MM_DD;
```

### RLS for a new table linked to a player

```sql
alter table public.new_table enable row level security;

create policy "new_table: coach sees own squads" on public.new_table
  for select using (
    is_admin() or player_id in (
      select p.id from players p
      where p.squad_id in (
        select squad_id from coach_squads where coach_id = auth.uid()
      )
    )
  );

create policy "new_table: coach can insert for own squads" on public.new_table
  for insert with check ( /* same condition as above */ );
```

If the table is linked to a squad instead of a player, use `squad_id in (select squad_id from coach_squads where coach_id = auth.uid())`.

## Deploying

1. Make changes on a branch.
2. Test with fake data by opening `index.html` locally with `?preview=1`. A real sign-in link won't redirect back to a local file, so test sign-in on the live site after merging.
3. Lucy runs any migration in the Supabase SQL Editor.
4. Open a pull request into `main` and merge it. GitHub Pages then publishes the update within a few minutes.

If a migration changes what existing data means, as the 1–4 to 1–5 scale change did, the old app and the new data don't match. So run the migration when no coach is using the app, then merge **straight away**. Say this clearly in the instructions to Lucy.

After an update, browsers can keep showing a saved copy of the old app. Sometimes that causes errors such as "Couldn't load data: NetworkError". The fix is a hard refresh (**Ctrl + Shift + R**, or **Cmd + Shift + R** on a Mac), or on a phone, closing the tab and reopening the app.

  -- =====================================================================
  -- Tests for 2026-11-18-drill-attempt-outcomes.sql (outcome names)
  --
  -- Run AFTER the migration, as one go, in the Supabase SQL Editor.
  --
  -- What it does, in plain language:
  --   - Creates two pretend squads (A and B), a player in each, and two
  --     pretend coaches: Coach A (squad A) and Coach B (squad B).
  --   - Gives squad A a pretend shooting drill (Goal 4, Post 3, Wide 2,
  --     Esther 1) and a drill where two buttons share the same points.
  --   - Signs in as each coach and checks outcome names are saved, checked
  --     against the points, filled in when missing, and private to the
  --     squad.
  --   - Then deliberately stops with a message, which UNDOES EVERYTHING.
  --     None of the pretend data is kept.
  --
  -- How to read the result:
  --   - "ALL 8 OUTCOME NAME TESTS PASSED" (shown as an error, on purpose)
  --     = all good.
  --   - "TEST n FAILED: ..." = something isn't working as intended.
  --     Don't merge the app change; send me the message.
  --   - Any other error = something about the test setup didn't fit your
  --     database. Send me the message.
  -- =====================================================================
  
  begin;
  
  -- ---------------------------------------------------------------------
  -- Pretend data (created with full rights, before signing in as anyone)
  -- ---------------------------------------------------------------------
  insert into auth.users (id, email) values
    ('00000000-0000-4000-8000-0000000000c1', 'test-coach-a@example.invalid'),
    ('00000000-0000-4000-8000-0000000000c3', 'test-coach-b@example.invalid');
  
  insert into public.profiles (id, email) values
    ('00000000-0000-4000-8000-0000000000c1', 'test-coach-a@example.invalid'),
    ('00000000-0000-4000-8000-0000000000c3', 'test-coach-b@example.invalid')
  on conflict (id) do nothing;
  
  insert into public.squads (id, name) values
    ('00000000-0000-4000-8000-0000000000a1', 'TEST Squad A'),
    ('00000000-0000-4000-8000-0000000000b1', 'TEST Squad B');
  
  insert into public.attributes (id, squad_id, name, category, sort_order) values
    ('00000000-0000-4000-8000-0000000000a2', '00000000-0000-4000-8000-0000000000a1', 'TEST Shooting', 'technical', 1);
  
  insert into public.players (id, squad_id, name, age) values
    ('00000000-0000-4000-8000-0000000000a3', '00000000-0000-4000-8000-0000000000a1', 'TEST Player A', 15),
    ('00000000-0000-4000-8000-0000000000b3', '00000000-0000-4000-8000-0000000000b1', 'TEST Player B', 15);
  
  insert into public.coach_squads (coach_id, squad_id, is_lead) values
    ('00000000-0000-4000-8000-0000000000c1', '00000000-0000-4000-8000-0000000000a1', false),
    ('00000000-0000-4000-8000-0000000000c3', '00000000-0000-4000-8000-0000000000b1', false);
  
  -- Shooting drill: 3 attempts, Goal 4, Post 3, Wide 2, Esther 1.
  -- "Same points" drill: Hit 2 and Close 2 share points, Miss 0.
  insert into public.drills (id, name, attribute_id, config) values
    ('00000000-0000-4000-8000-0000000000a4', 'TEST Shooting drill', '00000000-0000-4000-8000-0000000000a2',
     '{"attempts": 3, "results": [{"label": "Goal", "points": 4}, {"label": "Post", "points": 3},
       {"label": "Wide", "points": 2}, {"label": "Esther", "points": 1}],
       "retake_enabled": false, "retake_label": "Retake", "tags": [], "cutoffs": [40, 60, 75, 90]}'),
    ('00000000-0000-4000-8000-0000000000a6', 'TEST Same points drill', '00000000-0000-4000-8000-0000000000a2',
     '{"attempts": 2, "results": [{"label": "Hit", "points": 2}, {"label": "Close", "points": 2},
       {"label": "Miss", "points": 0}],
       "retake_enabled": false, "retake_label": "Retake", "tags": [], "cutoffs": [40, 60, 75, 90]}');
  
  -- From here on, act as a signed-in coach (RLS applies).
  set local role authenticated;
  
  -- =====================================================================
  -- As COACH A (squad A)
  -- =====================================================================
  select set_config('request.jwt.claims',
    '{"sub": "00000000-0000-4000-8000-0000000000c1", "role": "authenticated"}', true);
  
  do $$
  declare
    e record;
  begin
    -- 1. Names sent by the app are saved, in order.
    insert into drill_entries (drill_id, player_id, attempts, attempt_labels) values
      ('00000000-0000-4000-8000-0000000000a4', '00000000-0000-4000-8000-0000000000a3',
       '[4, 3, 1]', '["Goal", "Post", "Esther"]')
    returning * into e;
    if e.attempt_labels is distinct from '["Goal", "Post", "Esther"]'::jsonb then
      raise exception 'TEST 1 FAILED: expected Goal, Post, Esther; got %.', e.attempt_labels;
    end if;
  
    -- 2. The total and level are worked out exactly as before:
    --    8 of 12 = 66% → level 3.
    if e.total <> 8 or e.level <> 3 then
      raise exception 'TEST 2 FAILED: expected total 8 and level 3, got % and %.', e.total, e.level;
    end if;
  
    -- 3. With no names sent (e.g. an older copy of the app), the database
    --    fills them in from the points.
    insert into drill_entries (drill_id, player_id, attempts) values
      ('00000000-0000-4000-8000-0000000000a4', '00000000-0000-4000-8000-0000000000a3', '[2, 4, 2]')
    returning * into e;
    if e.attempt_labels is distinct from '["Wide", "Goal", "Wide"]'::jsonb then
      raise exception 'TEST 3 FAILED: expected Wide, Goal, Wide; got %.', e.attempt_labels;
    end if;
  
    -- 4. Where two buttons share the points, the name can't be guessed,
    --    so that position is left empty (Miss is still filled in).
    insert into drill_entries (drill_id, player_id, attempts) values
      ('00000000-0000-4000-8000-0000000000a6', '00000000-0000-4000-8000-0000000000a3', '[2, 0]')
    returning * into e;
    if e.attempt_labels is distinct from '[null, "Miss"]'::jsonb then
      raise exception 'TEST 4 FAILED: expected [null, Miss]; got %.', e.attempt_labels;
    end if;
  
    -- ...but the app, which knows which button was tapped, can save it.
    insert into drill_entries (drill_id, player_id, attempts, attempt_labels) values
      ('00000000-0000-4000-8000-0000000000a6', '00000000-0000-4000-8000-0000000000a3',
       '[2, 2]', '["Close", "Hit"]')
    returning * into e;
    if e.attempt_labels is distinct from '["Close", "Hit"]'::jsonb then
      raise exception 'TEST 4 FAILED: the app''s names for same-points buttons weren''t kept; got %.', e.attempt_labels;
    end if;
  end $$;
  
  do $$
  begin
    -- 5. A name that doesn't match its points is refused (Goal is 4, not 3).
    begin
      insert into drill_entries (drill_id, player_id, attempts, attempt_labels) values
        ('00000000-0000-4000-8000-0000000000a4', '00000000-0000-4000-8000-0000000000a3',
         '[3, 3, 1]', '["Goal", "Post", "Esther"]');
      raise exception 'TEST 5 FAILED: a name that didn''t match its points was accepted.';
    exception
      when raise_exception then
        if sqlerrm like 'TEST 5 FAILED%' then raise; end if;
    end;
  
    -- 6. A name that isn't one of the drill's buttons is refused, and so
    --    is the wrong number of names.
    begin
      insert into drill_entries (drill_id, player_id, attempts, attempt_labels) values
        ('00000000-0000-4000-8000-0000000000a4', '00000000-0000-4000-8000-0000000000a3',
         '[4, 3, 1]', '["Goal", "Crossbar", "Esther"]');
      raise exception 'TEST 6 FAILED: an unknown outcome name was accepted.';
    exception
      when raise_exception then
        if sqlerrm like 'TEST 6 FAILED%' then raise; end if;
    end;
    begin
      insert into drill_entries (drill_id, player_id, attempts, attempt_labels) values
        ('00000000-0000-4000-8000-0000000000a4', '00000000-0000-4000-8000-0000000000a3',
         '[4, 3, 1]', '["Goal", "Post"]');
      raise exception 'TEST 6 FAILED: the wrong number of outcome names was accepted.';
    exception
      when raise_exception then
        if sqlerrm like 'TEST 6 FAILED%' then raise; end if;
    end;
  
    -- 7. Coach A still can't save a run for squad B's player.
    begin
      insert into drill_entries (drill_id, player_id, attempts, attempt_labels) values
        ('00000000-0000-4000-8000-0000000000a4', '00000000-0000-4000-8000-0000000000b3',
         '[4, 4, 4]', '["Goal", "Goal", "Goal"]');
      raise exception 'TEST 7 FAILED: Coach A saved a run for squad B''s player.';
    exception
      when raise_exception then
        if sqlerrm like 'TEST 7 FAILED%' then raise; end if;
      when others then null;  -- blocked, as intended
    end;
  end $$;
  
  -- =====================================================================
  -- As COACH B (squad B)
  -- =====================================================================
  select set_config('request.jwt.claims',
    '{"sub": "00000000-0000-4000-8000-0000000000c3", "role": "authenticated"}', true);
  
  do $$
  begin
    -- 8. Coach B can't see squad A's runs, or their outcome names.
    if (select count(*) from drill_entries
        where player_id = '00000000-0000-4000-8000-0000000000a3') <> 0 then
      raise exception 'TEST 8 FAILED: Coach B can see squad A''s runs.';
    end if;
  end $$;
  
  -- =====================================================================
  -- All passed: stop on purpose so everything above is undone.
  -- =====================================================================
  do $$
  begin
    raise exception 'ALL 8 OUTCOME NAME TESTS PASSED. (This is shown as an error on purpose: it undoes all the pretend test data, so nothing is kept.)';
  end $$;
  
  rollback;

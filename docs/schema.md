[
  {
    "table_name": "attributes",
    "column_name": "id",
    "data_type": "uuid"
  },
  {
    "table_name": "attributes",
    "column_name": "squad_id",
    "data_type": "uuid"
  },
  {
    "table_name": "attributes",
    "column_name": "name",
    "data_type": "text"
  },
  {
    "table_name": "attributes",
    "column_name": "sort_order",
    "data_type": "integer"
  },
  {
    "table_name": "attributes",
    "column_name": "category",
    "data_type": "text"
  },
  {
    "table_name": "attributes",
    "column_name": "description",
    "data_type": "text"
  },
  {
    "table_name": "attributes",
    "column_name": "sport",
    "data_type": "text"
  },
  {
    "table_name": "coach_squads",
    "column_name": "coach_id",
    "data_type": "uuid"
  },
  {
    "table_name": "coach_squads",
    "column_name": "squad_id",
    "data_type": "uuid"
  },
  {
    "table_name": "feedback",
    "column_name": "id",
    "data_type": "uuid"
  },
  {
    "table_name": "feedback",
    "column_name": "player_id",
    "data_type": "uuid"
  },
  {
    "table_name": "feedback",
    "column_name": "note",
    "data_type": "text"
  },
  {
    "table_name": "feedback",
    "column_name": "coach_id",
    "data_type": "uuid"
  },
  {
    "table_name": "feedback",
    "column_name": "created_at",
    "data_type": "timestamp with time zone"
  },
  {
    "table_name": "players",
    "column_name": "id",
    "data_type": "uuid"
  },
  {
    "table_name": "players",
    "column_name": "name",
    "data_type": "text"
  },
  {
    "table_name": "players",
    "column_name": "age",
    "data_type": "integer"
  },
  {
    "table_name": "players",
    "column_name": "squad_id",
    "data_type": "uuid"
  },
  {
    "table_name": "players",
    "column_name": "position",
    "data_type": "text"
  },
  {
    "table_name": "players",
    "column_name": "role",
    "data_type": "text"
  },
  {
    "table_name": "profiles",
    "column_name": "id",
    "data_type": "uuid"
  },
  {
    "table_name": "profiles",
    "column_name": "email",
    "data_type": "text"
  },
  {
    "table_name": "profiles",
    "column_name": "role",
    "data_type": "text"
  },
  {
    "table_name": "scores",
    "column_name": "id",
    "data_type": "uuid"
  },
  {
    "table_name": "scores",
    "column_name": "player_id",
    "data_type": "uuid"
  },
  {
    "table_name": "scores",
    "column_name": "attribute_id",
    "data_type": "uuid"
  },
  {
    "table_name": "scores",
    "column_name": "value",
    "data_type": "integer"
  },
  {
    "table_name": "scores",
    "column_name": "scored_by",
    "data_type": "uuid"
  },
  {
    "table_name": "scores",
    "column_name": "scored_at",
    "data_type": "timestamp with time zone"
  },
  {
    "table_name": "squads",
    "column_name": "id",
    "data_type": "uuid"
  },
  {
    "table_name": "squads",
    "column_name": "name",
    "data_type": "text"
  }
]

[
  {
    "tablename": "attributes",
    "policyname": "skills readable by any logged-in user",
    "cmd": "SELECT",
    "qual": "(auth.role() = 'authenticated'::text)",
    "with_check": null
  },
  {
    "tablename": "squads",
    "policyname": "squads readable by any logged-in user",
    "cmd": "SELECT",
    "qual": "(auth.role() = 'authenticated'::text)",
    "with_check": null
  },
  {
    "tablename": "feedback",
    "policyname": "feedback: coach can insert for own squads",
    "cmd": "INSERT",
    "qual": null,
    "with_check": "(is_admin() OR (player_id IN ( SELECT p.id\n   FROM players p\n  WHERE (p.squad_id IN ( SELECT coach_squads.squad_id\n           FROM coach_squads\n          WHERE (coach_squads.coach_id = auth.uid()))))))"
  },
  {
    "tablename": "feedback",
    "policyname": "feedback: coach sees own squads",
    "cmd": "SELECT",
    "qual": "(is_admin() OR (player_id IN ( SELECT p.id\n   FROM players p\n  WHERE (p.squad_id IN ( SELECT coach_squads.squad_id\n           FROM coach_squads\n          WHERE (coach_squads.coach_id = auth.uid()))))))",
    "with_check": null
  },
  {
    "tablename": "profiles",
    "policyname": "profiles: self or admin",
    "cmd": "SELECT",
    "qual": "((id = auth.uid()) OR is_admin())",
    "with_check": null
  },
  {
    "tablename": "coach_squads",
    "policyname": "coach_squads: admin can manage",
    "cmd": "ALL",
    "qual": "is_admin()",
    "with_check": null
  },
  {
    "tablename": "coach_squads",
    "policyname": "coach_squads: self or admin",
    "cmd": "SELECT",
    "qual": "((coach_id = auth.uid()) OR is_admin())",
    "with_check": null
  },
  {
    "tablename": "scores",
    "policyname": "scores: coach can insert for own squads",
    "cmd": "INSERT",
    "qual": null,
    "with_check": "(is_admin() OR (player_id IN ( SELECT p.id\n   FROM players p\n  WHERE (p.squad_id IN ( SELECT coach_squads.squad_id\n           FROM coach_squads\n          WHERE (coach_squads.coach_id = auth.uid()))))))"
  },
  {
    "tablename": "scores",
    "policyname": "scores: coach sees own squads",
    "cmd": "SELECT",
    "qual": "(is_admin() OR (player_id IN ( SELECT p.id\n   FROM players p\n  WHERE (p.squad_id IN ( SELECT coach_squads.squad_id\n           FROM coach_squads\n          WHERE (coach_squads.coach_id = auth.uid()))))))",
    "with_check": null
  },
  {
    "tablename": "players",
    "policyname": "players: admin can delete",
    "cmd": "DELETE",
    "qual": "is_admin()",
    "with_check": null
  },
  {
    "tablename": "players",
    "policyname": "players: admin can manage",
    "cmd": "INSERT",
    "qual": null,
    "with_check": "is_admin()"
  },
  {
    "tablename": "players",
    "policyname": "players: admin can update",
    "cmd": "UPDATE",
    "qual": "is_admin()",
    "with_check": null
  },
  {
    "tablename": "players",
    "policyname": "players: coach sees own squads",
    "cmd": "SELECT",
    "qual": "(is_admin() OR (squad_id IN ( SELECT coach_squads.squad_id\n   FROM coach_squads\n  WHERE (coach_squads.coach_id = auth.uid()))))",
    "with_check": null
  }
]

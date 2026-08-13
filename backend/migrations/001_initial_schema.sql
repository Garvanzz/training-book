-- Training Book initial schema. Run inside a transaction through Alembic.
-- Application requests must set `SET LOCAL app.user_id = '<uuid>'` before touching
-- user-owned tables. No client has direct database credentials.

CREATE SCHEMA IF NOT EXISTS app;

CREATE OR REPLACE FUNCTION app.current_user_id()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
    SELECT NULLIF(current_setting('app.user_id', true), '')::uuid;
$$;

CREATE TABLE users (
    id uuid PRIMARY KEY,
    email text NOT NULL UNIQUE,
    password_hash text NOT NULL,
    is_active boolean NOT NULL DEFAULT true,
    is_owner boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz
);

CREATE TABLE profiles (
    user_id uuid PRIMARY KEY REFERENCES users(id),
    display_name text NOT NULL,
    locale text NOT NULL DEFAULT 'zh-CN',
    timezone text NOT NULL DEFAULT 'Asia/Shanghai',
    unit_system text NOT NULL DEFAULT 'metric'
        CHECK (unit_system IN ('metric', 'imperial')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    revision bigint NOT NULL DEFAULT 1,
    deleted_at timestamptz
);

CREATE TABLE device_sessions (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id),
    device_id uuid NOT NULL,
    device_name text NOT NULL,
    platform text NOT NULL CHECK (platform IN ('ios', 'windows')),
    refresh_token_hash text NOT NULL,
    refresh_expires_at timestamptz NOT NULL,
    offline_lease_expires_at timestamptz NOT NULL,
    last_online_at timestamptz NOT NULL DEFAULT now(),
    revoked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (user_id, device_id)
);

CREATE TABLE user_settings (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id),
    setting_key text NOT NULL,
    value_json jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    revision bigint NOT NULL DEFAULT 1,
    deleted_at timestamptz,
    UNIQUE (user_id, setting_key)
);

CREATE TABLE equipment (
    id uuid PRIMARY KEY,
    code text NOT NULL UNIQUE,
    name_zh text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE user_equipment (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id),
    equipment_id uuid NOT NULL REFERENCES equipment(id),
    available boolean NOT NULL DEFAULT true,
    increments_json jsonb NOT NULL DEFAULT '[]'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    revision bigint NOT NULL DEFAULT 1,
    deleted_at timestamptz,
    UNIQUE (user_id, equipment_id)
);

CREATE TABLE taxonomy_terms (
    id uuid PRIMARY KEY,
    dimension text NOT NULL,
    code text NOT NULL,
    parent_id uuid REFERENCES taxonomy_terms(id),
    name_zh text NOT NULL,
    name_en text,
    sort_order integer NOT NULL DEFAULT 0,
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (dimension, code)
);

CREATE TABLE exercises (
    id uuid PRIMARY KEY,
    source text NOT NULL CHECK (source IN ('system', 'user')),
    owner_user_id uuid REFERENCES users(id),
    status text NOT NULL CHECK (status IN ('draft', 'published', 'deprecated', 'withdrawn')),
    current_published_version integer,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    CHECK ((source = 'system' AND owner_user_id IS NULL) OR source = 'user')
);

CREATE TABLE exercise_versions (
    id uuid PRIMARY KEY,
    exercise_id uuid NOT NULL REFERENCES exercises(id),
    version_no integer NOT NULL,
    status text NOT NULL CHECK (status IN ('draft', 'in_review', 'published', 'withdrawn')),
    name_zh text NOT NULL,
    name_en text,
    summary text NOT NULL,
    instructions_json jsonb NOT NULL,
    cues_json jsonb NOT NULL DEFAULT '[]'::jsonb,
    mistakes_json jsonb NOT NULL DEFAULT '[]'::jsonb,
    safety_json jsonb NOT NULL DEFAULT '[]'::jsonb,
    recording_mode text NOT NULL CHECK (recording_mode IN (
        'load_reps', 'duration', 'distance', 'load_duration', 'assisted_bodyweight', 'mixed'
    )),
    content_hash text NOT NULL,
    author_user_id uuid NOT NULL REFERENCES users(id),
    reviewed_by_user_id uuid REFERENCES users(id),
    reviewed_at timestamptz,
    change_summary text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    published_at timestamptz,
    UNIQUE (exercise_id, version_no),
    UNIQUE (exercise_id, content_hash)
);

ALTER TABLE exercises
    ADD CONSTRAINT exercises_current_version_fk
    FOREIGN KEY (id, current_published_version)
    REFERENCES exercise_versions(exercise_id, version_no)
    DEFERRABLE INITIALLY DEFERRED;

CREATE TABLE exercise_terms (
    exercise_version_id uuid NOT NULL REFERENCES exercise_versions(id) ON DELETE CASCADE,
    term_id uuid NOT NULL REFERENCES taxonomy_terms(id),
    is_primary boolean NOT NULL DEFAULT false,
    PRIMARY KEY (exercise_version_id, term_id)
);

CREATE TABLE exercise_media (
    id uuid PRIMARY KEY,
    exercise_version_id uuid NOT NULL REFERENCES exercise_versions(id) ON DELETE CASCADE,
    media_type text NOT NULL CHECK (media_type IN ('video', 'image', 'cover', 'keyframe')),
    object_key text NOT NULL UNIQUE,
    preview_object_key text,
    sha256 text NOT NULL,
    width integer,
    height integer,
    duration_ms integer,
    content_type text NOT NULL,
    license_type text NOT NULL,
    rights_holder text NOT NULL,
    rights_expires_at timestamptz,
    alt_text_zh text NOT NULL,
    status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'ready', 'published', 'withdrawn')),
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE exercise_relations (
    from_exercise_id uuid NOT NULL REFERENCES exercises(id),
    to_exercise_id uuid NOT NULL REFERENCES exercises(id),
    relation_type text NOT NULL CHECK (relation_type IN ('regression', 'progression', 'substitution')),
    rule_json jsonb NOT NULL DEFAULT '{}'::jsonb,
    PRIMARY KEY (from_exercise_id, to_exercise_id, relation_type),
    CHECK (from_exercise_id <> to_exercise_id)
);

CREATE TABLE library_releases (
    id uuid PRIMARY KEY,
    release_no bigint NOT NULL UNIQUE,
    status text NOT NULL CHECK (status IN ('draft', 'published', 'rolled_back')),
    manifest_hash text NOT NULL,
    min_client_schema integer NOT NULL,
    published_by_user_id uuid REFERENCES users(id),
    published_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE library_release_items (
    release_id uuid NOT NULL REFERENCES library_releases(id) ON DELETE CASCADE,
    exercise_version_id uuid NOT NULL REFERENCES exercise_versions(id),
    PRIMARY KEY (release_id, exercise_version_id)
);

CREATE TABLE plans (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id),
    name text NOT NULL,
    goal_json jsonb NOT NULL DEFAULT '{}'::jsonb,
    current_version_no integer,
    status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'archived')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    revision bigint NOT NULL DEFAULT 1,
    deleted_at timestamptz
);

CREATE TABLE plan_versions (
    id uuid PRIMARY KEY,
    plan_id uuid NOT NULL REFERENCES plans(id),
    version_no integer NOT NULL,
    based_on_version_no integer,
    is_published boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    published_at timestamptz,
    UNIQUE (plan_id, version_no)
);

ALTER TABLE plans
    ADD CONSTRAINT plans_current_version_fk
    FOREIGN KEY (id, current_version_no)
    REFERENCES plan_versions(plan_id, version_no)
    DEFERRABLE INITIALLY DEFERRED;

CREATE TABLE session_templates (
    id uuid PRIMARY KEY,
    plan_version_id uuid NOT NULL REFERENCES plan_versions(id) ON DELETE CASCADE,
    name text NOT NULL,
    weekday integer CHECK (weekday BETWEEN 1 AND 7),
    estimated_duration_seconds integer,
    sort_order integer NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (plan_version_id, sort_order)
);

CREATE TABLE stage_blocks (
    id uuid PRIMARY KEY,
    session_template_id uuid NOT NULL REFERENCES session_templates(id) ON DELETE CASCADE,
    purpose text NOT NULL CHECK (purpose IN (
        'readiness', 'general_warmup', 'mobility', 'activation_control', 'movement_prep',
        'power_skill', 'primary_strength', 'accessory', 'local_endurance', 'conditioning',
        'cooldown_recovery'
    )),
    custom_name text,
    config_json jsonb NOT NULL DEFAULT '{}'::jsonb,
    sort_order integer NOT NULL,
    UNIQUE (session_template_id, sort_order)
);

CREATE TABLE exercise_slots (
    id uuid PRIMARY KEY,
    stage_block_id uuid NOT NULL REFERENCES stage_blocks(id) ON DELETE CASCADE,
    exercise_id uuid NOT NULL REFERENCES exercises(id),
    exercise_version_no integer,
    group_id uuid,
    group_type text NOT NULL DEFAULT 'single' CHECK (group_type IN ('single', 'superset', 'circuit', 'giant_set')),
    side_mode text NOT NULL DEFAULT 'combined' CHECK (side_mode IN ('combined', 'per_side', 'left_right')),
    sort_order integer NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (stage_block_id, sort_order),
    FOREIGN KEY (exercise_id, exercise_version_no)
        REFERENCES exercise_versions(exercise_id, version_no)
        DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE prescriptions (
    id uuid PRIMARY KEY,
    exercise_slot_id uuid NOT NULL UNIQUE REFERENCES exercise_slots(id) ON DELETE CASCADE,
    prescription_type text NOT NULL CHECK (prescription_type IN (
        'fixed_sets_reps', 'rep_range', 'amrap', 'emom', 'duration', 'distance', 'free'
    )),
    set_count integer,
    rep_min integer,
    rep_max integer,
    target_load_kg numeric(9,3),
    target_rpe numeric(3,1),
    target_rir numeric(3,1),
    rest_seconds integer,
    tempo text,
    parameters_json jsonb NOT NULL DEFAULT '{}'::jsonb,
    progression_policy_json jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE slot_alternatives (
    id uuid PRIMARY KEY,
    exercise_slot_id uuid NOT NULL REFERENCES exercise_slots(id) ON DELETE CASCADE,
    alternative_exercise_id uuid REFERENCES exercises(id),
    rule_json jsonb NOT NULL DEFAULT '{}'::jsonb,
    priority integer NOT NULL DEFAULT 0,
    CHECK (alternative_exercise_id IS NOT NULL OR rule_json <> '{}'::jsonb)
);

CREATE TABLE workout_sessions (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id),
    source_plan_version_id uuid REFERENCES plan_versions(id),
    source_session_template_id uuid REFERENCES session_templates(id),
    session_snapshot jsonb NOT NULL,
    status text NOT NULL CHECK (status IN ('in_progress', 'completed', 'abandoned')),
    started_at timestamptz NOT NULL,
    ended_at timestamptz,
    timezone text NOT NULL,
    active_device_id uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    revision bigint NOT NULL DEFAULT 1,
    deleted_at timestamptz
);

CREATE TABLE workout_items (
    id uuid PRIMARY KEY,
    workout_session_id uuid NOT NULL REFERENCES workout_sessions(id) ON DELETE CASCADE,
    source_slot_id uuid REFERENCES exercise_slots(id),
    exercise_id uuid NOT NULL REFERENCES exercises(id),
    exercise_version_no integer,
    exercise_snapshot jsonb NOT NULL,
    prescription_snapshot jsonb NOT NULL,
    replacement_reason text,
    sort_order integer NOT NULL,
    UNIQUE (workout_session_id, sort_order)
);

CREATE TABLE set_logs (
    id uuid PRIMARY KEY,
    workout_item_id uuid NOT NULL REFERENCES workout_items(id) ON DELETE CASCADE,
    set_number integer NOT NULL,
    set_type text NOT NULL CHECK (set_type IN ('warmup', 'working', 'backoff', 'drop', 'test')),
    status text NOT NULL CHECK (status IN ('planned', 'completed', 'skipped', 'failed')),
    load_kg numeric(9,3),
    original_load numeric(9,3),
    original_unit text CHECK (original_unit IN ('kg', 'lb')),
    is_per_side boolean NOT NULL DEFAULT false,
    includes_bar boolean,
    reps integer,
    duration_seconds integer,
    distance_meters numeric(10,2),
    rpe numeric(3,1),
    rir numeric(3,1),
    pain_score integer CHECK (pain_score BETWEEN 0 AND 10),
    technique_ok boolean,
    notes text,
    performed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    revision bigint NOT NULL DEFAULT 1,
    UNIQUE (workout_item_id, set_number)
);

CREATE TABLE progression_suggestions (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id),
    exercise_slot_id uuid REFERENCES exercise_slots(id),
    workout_item_id uuid REFERENCES workout_items(id),
    algorithm_version text NOT NULL,
    input_summary jsonb NOT NULL,
    suggestion_json jsonb NOT NULL,
    rationale text NOT NULL,
    decision text NOT NULL DEFAULT 'pending' CHECK (decision IN ('pending', 'accepted', 'modified', 'dismissed')),
    decided_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE sync_operations (
    operation_id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id),
    device_id uuid NOT NULL,
    entity_type text NOT NULL,
    entity_id uuid NOT NULL,
    operation_type text NOT NULL CHECK (operation_type IN ('create', 'update', 'delete')),
    base_revision bigint,
    payload jsonb NOT NULL,
    result text NOT NULL CHECK (result IN ('accepted', 'conflict', 'rejected')),
    result_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    server_cursor bigint NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX sync_operations_user_cursor_idx ON sync_operations (user_id, server_cursor);
CREATE INDEX workout_sessions_user_started_idx ON workout_sessions (user_id, started_at DESC);
CREATE INDEX set_logs_item_idx ON set_logs (workout_item_id, set_number);
CREATE INDEX exercise_versions_name_idx ON exercise_versions (name_zh);

CREATE TABLE audit_logs (
    id uuid PRIMARY KEY,
    actor_user_id uuid REFERENCES users(id),
    action text NOT NULL,
    entity_type text NOT NULL,
    entity_id uuid NOT NULL,
    before_json jsonb,
    after_json jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- Personal tables are deny-by-default. The API must set app.user_id within each
-- transaction; a missing setting evaluates to NULL and matches no row.
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE device_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_equipment ENABLE ROW LEVEL SECURITY;
ALTER TABLE plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE plan_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE session_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE stage_blocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE exercise_slots ENABLE ROW LEVEL SECURITY;
ALTER TABLE prescriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE slot_alternatives ENABLE ROW LEVEL SECURITY;
ALTER TABLE workout_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE workout_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE set_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE progression_suggestions ENABLE ROW LEVEL SECURITY;
ALTER TABLE sync_operations ENABLE ROW LEVEL SECURITY;

CREATE POLICY profiles_owner ON profiles
    USING (user_id = app.current_user_id())
    WITH CHECK (user_id = app.current_user_id());
CREATE POLICY device_sessions_owner ON device_sessions
    USING (user_id = app.current_user_id())
    WITH CHECK (user_id = app.current_user_id());
CREATE POLICY user_settings_owner ON user_settings
    USING (user_id = app.current_user_id())
    WITH CHECK (user_id = app.current_user_id());
CREATE POLICY user_equipment_owner ON user_equipment
    USING (user_id = app.current_user_id())
    WITH CHECK (user_id = app.current_user_id());
CREATE POLICY plans_owner ON plans
    USING (user_id = app.current_user_id())
    WITH CHECK (user_id = app.current_user_id());
CREATE POLICY plan_versions_owner ON plan_versions
    USING (EXISTS (SELECT 1 FROM plans p WHERE p.id = plan_versions.plan_id AND p.user_id = app.current_user_id()));
CREATE POLICY session_templates_owner ON session_templates
    USING (EXISTS (
        SELECT 1 FROM plan_versions pv JOIN plans p ON p.id = pv.plan_id
        WHERE pv.id = session_templates.plan_version_id AND p.user_id = app.current_user_id()
    ));
CREATE POLICY stage_blocks_owner ON stage_blocks
    USING (EXISTS (
        SELECT 1
        FROM session_templates st
        JOIN plan_versions pv ON pv.id = st.plan_version_id
        JOIN plans p ON p.id = pv.plan_id
        WHERE st.id = stage_blocks.session_template_id AND p.user_id = app.current_user_id()
    ));
CREATE POLICY exercise_slots_owner ON exercise_slots
    USING (EXISTS (
        SELECT 1
        FROM stage_blocks sb
        JOIN session_templates st ON st.id = sb.session_template_id
        JOIN plan_versions pv ON pv.id = st.plan_version_id
        JOIN plans p ON p.id = pv.plan_id
        WHERE sb.id = exercise_slots.stage_block_id AND p.user_id = app.current_user_id()
    ));
CREATE POLICY prescriptions_owner ON prescriptions
    USING (EXISTS (
        SELECT 1
        FROM exercise_slots es
        JOIN stage_blocks sb ON sb.id = es.stage_block_id
        JOIN session_templates st ON st.id = sb.session_template_id
        JOIN plan_versions pv ON pv.id = st.plan_version_id
        JOIN plans p ON p.id = pv.plan_id
        WHERE es.id = prescriptions.exercise_slot_id AND p.user_id = app.current_user_id()
    ));
CREATE POLICY slot_alternatives_owner ON slot_alternatives
    USING (EXISTS (
        SELECT 1
        FROM exercise_slots es
        JOIN stage_blocks sb ON sb.id = es.stage_block_id
        JOIN session_templates st ON st.id = sb.session_template_id
        JOIN plan_versions pv ON pv.id = st.plan_version_id
        JOIN plans p ON p.id = pv.plan_id
        WHERE es.id = slot_alternatives.exercise_slot_id AND p.user_id = app.current_user_id()
    ));
CREATE POLICY workout_sessions_owner ON workout_sessions
    USING (user_id = app.current_user_id())
    WITH CHECK (user_id = app.current_user_id());
CREATE POLICY workout_items_owner ON workout_items
    USING (EXISTS (
        SELECT 1 FROM workout_sessions ws
        WHERE ws.id = workout_items.workout_session_id AND ws.user_id = app.current_user_id()
    ));
CREATE POLICY set_logs_owner ON set_logs
    USING (EXISTS (
        SELECT 1
        FROM workout_items wi
        JOIN workout_sessions ws ON ws.id = wi.workout_session_id
        WHERE wi.id = set_logs.workout_item_id AND ws.user_id = app.current_user_id()
    ));
CREATE POLICY progression_suggestions_owner ON progression_suggestions
    USING (user_id = app.current_user_id())
    WITH CHECK (user_id = app.current_user_id());
CREATE POLICY sync_operations_owner ON sync_operations
    USING (user_id = app.current_user_id())
    WITH CHECK (user_id = app.current_user_id());

-- D-NAVIO T4.2 — shared relational store
--
-- D4.1 §6.1.2 defines a shared relational store for "structured data and outputs", and
-- D2.3 §5.4 is specific: "relational storage (PostgreSQL) for schema-compliant, structured
-- failure records amenable to statistical query; and NoSQL storage (MongoDB) for
-- unstructured or semi-structured log data, raw sensor streams, and flexible incident
-- metadata."
--
-- This file therefore holds the queryable projections. Raw envelopes and unstructured
-- evidence live in MongoDB (see db/mongo/init.js).

BEGIN;

CREATE SCHEMA IF NOT EXISTS dnavio;
SET search_path TO dnavio, public;

-- =====================================================================================
-- DML — telemetry observations
-- =====================================================================================

-- Partitioned by observation month. The Grant Agreement sizes T4.2 at 5-10 TB across the
-- project lifetime; a single unpartitioned table would not survive that. Partitioning also
-- makes the retention policy a DETACH rather than a mass DELETE.
CREATE TABLE IF NOT EXISTS iot_observation (
    observed_at     timestamptz      NOT NULL,
    event_id        uuid             NOT NULL,
    ingested_at     timestamptz      NOT NULL DEFAULT now(),
    vessel_id       text             NOT NULL,
    system          text             NOT NULL,
    subsystem       text,
    sensor_id       text,
    tag             text,
    metric          text             NOT NULL,
    value_num       double precision,
    value_text      text,
    value_bool      boolean,
    unit            text,
    quality_status  text             NOT NULL DEFAULT 'good',
    quality_flags   text[]           NOT NULL DEFAULT '{}',
    completeness    real,
    schema_version  text             NOT NULL,
    correlation_id  text,
    provenance      jsonb            NOT NULL DEFAULT '{}'::jsonb,
    tags            jsonb            NOT NULL DEFAULT '{}'::jsonb,
    -- event_id is part of the key so at-least-once redelivery is a no-op, not a duplicate.
    PRIMARY KEY (observed_at, event_id)
) PARTITION BY RANGE (observed_at);

-- Catch-all partition. Real deployments would pre-create monthly partitions; for the
-- demonstrator a single DEFAULT keeps the pilot replay (Jul 2025 - Apr 2026) in one place
-- while leaving the partitioned structure in force.
CREATE TABLE IF NOT EXISTS iot_observation_default
    PARTITION OF iot_observation DEFAULT;

CREATE INDEX IF NOT EXISTS idx_obs_vessel_metric_time
    ON iot_observation (vessel_id, metric, observed_at DESC);
CREATE INDEX IF NOT EXISTS idx_obs_time
    ON iot_observation (observed_at DESC);
-- Supports the data-quality indicators the DML contributes to KPI-2.
CREATE INDEX IF NOT EXISTS idx_obs_quality
    ON iot_observation (vessel_id, quality_status)
    WHERE quality_status <> 'good';

-- Latest-value projection. Cheap read model for "current state" queries; maintained by
-- stream-processor on write rather than computed by a window function at read time.
CREATE TABLE IF NOT EXISTS iot_observation_latest (
    vessel_id       text             NOT NULL,
    metric          text             NOT NULL,
    observed_at     timestamptz      NOT NULL,
    event_id        uuid             NOT NULL,
    system          text,
    subsystem       text,
    sensor_id       text,
    value_num       double precision,
    value_text      text,
    value_bool      boolean,
    unit            text,
    quality_status  text,
    quality_flags   text[],
    updated_at      timestamptz      NOT NULL DEFAULT now(),
    PRIMARY KEY (vessel_id, metric)
);

-- =====================================================================================
-- FRS — immutable failure-event log
-- =====================================================================================

-- D4.1 §4.3.8 requires the FRS to maintain "Immutable audit logs of failure events and
-- system-state transitions", and calls the FRS "the primary audit and logging layer of the
-- platform". The GA is equally explicit: "maintaining immutable user logs for accountability
-- and transparency".
--
-- Immutability here is enforced three ways:
--   1. a BEFORE UPDATE OR DELETE trigger that raises unconditionally,
--   2. a SHA-256 hash chain, so any out-of-band mutation (superuser, direct file edit)
--      breaks verification and is detectable after the fact,
--   3. no application code path that issues UPDATE or DELETE against this table.
--
-- Append-only is not the same as tamper-proof. A determined superuser can still rewrite
-- rows and recompute the chain. Genuine tamper-evidence needs external anchoring — see
-- docs/open-questions.md.
CREATE TABLE IF NOT EXISTS failure_event (
    seq             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id        uuid             NOT NULL UNIQUE,
    report_id       uuid             NOT NULL,
    vessel_id       text             NOT NULL,
    -- submitted | state-changed | escalated | classified
    event_type      text             NOT NULL,
    occurred_at     timestamptz      NOT NULL,
    recorded_at     timestamptz      NOT NULL DEFAULT now(),
    actor           text             NOT NULL,
    -- json, deliberately, not jsonb. jsonb normalises: it reorders object keys and strips
    -- insignificant whitespace, so the bytes read back are not the bytes written. Hashing
    -- the payload then fails verification on every record even when nothing was tampered
    -- with. json stores the text verbatim, which is what a hash chain requires.
    payload         json             NOT NULL,
    prev_hash       bytea,
    hash            bytea            NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_fevent_report ON failure_event (report_id, seq);
CREATE INDEX IF NOT EXISTS idx_fevent_vessel_time ON failure_event (vessel_id, occurred_at DESC);

CREATE OR REPLACE FUNCTION dnavio.deny_mutation() RETURNS trigger AS $$
BEGIN
    RAISE EXCEPTION
        'failure_event is append-only: % denied on the FRS immutable audit log (D4.1 §4.3.8)',
        TG_OP;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_failure_event_immutable ON failure_event;
CREATE TRIGGER trg_failure_event_immutable
    BEFORE UPDATE OR DELETE ON failure_event
    FOR EACH ROW EXECUTE FUNCTION dnavio.deny_mutation();

-- =====================================================================================
-- FRS — current-state projection
-- =====================================================================================

-- The append-only log above is the source of truth. This table is a derived read model, so
-- that "show me open failures on DG2" is an index lookup rather than a fold over history.
CREATE TABLE IF NOT EXISTS failure_report (
    report_id           uuid            PRIMARY KEY,
    vessel_id           text            NOT NULL,
    system              text            NOT NULL,
    subsystem           text,
    asset_id            text,
    detected_at         timestamptz     NOT NULL,
    started_at          timestamptz,
    ended_at            timestamptz,
    reported_by         text            NOT NULL,
    origin              text            NOT NULL,
    event_class         text            NOT NULL,
    taxonomy_version    text            NOT NULL,
    taxonomy_code       text            NOT NULL,
    taxonomy_label      text,
    severity_csn        smallint        NOT NULL,
    severity_label      text,
    priority_tier       text,
    priority_rationale  text,
    status              text            NOT NULL,
    summary             text            NOT NULL,
    description         text,
    confidence          real,
    hydra_node_refs     jsonb           NOT NULL DEFAULT '[]'::jsonb,
    escalated           boolean         NOT NULL DEFAULT false,
    escalation          jsonb,
    evidence            jsonb           NOT NULL DEFAULT '{}'::jsonb,
    tags                jsonb           NOT NULL DEFAULT '{}'::jsonb,
    schema_version      text            NOT NULL,
    created_at          timestamptz     NOT NULL DEFAULT now(),
    updated_at          timestamptz     NOT NULL DEFAULT now(),

    CONSTRAINT chk_origin      CHECK (origin      IN ('derived','synthetic','manual','external')),
    CONSTRAINT chk_event_class CHECK (event_class IN ('failure','anomaly','state-transition','data-quality')),
    CONSTRAINT chk_status      CHECK (status      IN ('open','acknowledged','mitigated','closed')),
    CONSTRAINT chk_csn         CHECK (severity_csn BETWEEN 1 AND 10)
);

-- FR-INC-02: "search/filter incidents by time window, severity, component, DT/model version".
CREATE INDEX IF NOT EXISTS idx_freport_vessel_time  ON failure_report (vessel_id, detected_at DESC);
CREATE INDEX IF NOT EXISTS idx_freport_severity     ON failure_report (severity_csn DESC, detected_at DESC);
CREATE INDEX IF NOT EXISTS idx_freport_component    ON failure_report (system, subsystem);
CREATE INDEX IF NOT EXISTS idx_freport_status       ON failure_report (status) WHERE status <> 'closed';
CREATE INDEX IF NOT EXISTS idx_freport_class_origin ON failure_report (event_class, origin);
CREATE INDEX IF NOT EXISTS idx_freport_taxonomy     ON failure_report (taxonomy_code);
-- GIN over node refs so HYDRA can ask "every record touching ASN:DGStatus" (D2.3 §5.4
-- contextual retrieval).
CREATE INDEX IF NOT EXISTS idx_freport_hydra_nodes  ON failure_report USING gin (hydra_node_refs jsonb_path_ops);

-- =====================================================================================
-- FRS — HYDRA probability update packages
-- =====================================================================================

CREATE TABLE IF NOT EXISTS hydra_probability_update (
    package_id      uuid            PRIMARY KEY,
    generated_at    timestamptz     NOT NULL,
    trigger         text            NOT NULL,
    vessel_id       text            NOT NULL,
    node_type       text            NOT NULL,
    node_id         text            NOT NULL,
    states          text[]          NOT NULL,
    distribution    jsonb           NOT NULL,
    window_from     timestamptz     NOT NULL,
    window_to       timestamptz     NOT NULL,
    sample_size     bigint          NOT NULL,
    observed_count  bigint          NOT NULL,
    quality         jsonb           NOT NULL,
    provenance      jsonb           NOT NULL,
    co_occurrence   jsonb           NOT NULL DEFAULT '[]'::jsonb,
    schema_version  text            NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_hydra_node_time ON hydra_probability_update (node_id, generated_at DESC);

-- =====================================================================================
-- Lineage and governance
-- =====================================================================================

-- Which rule fired, over which window, from which observations. This is what lets a
-- reviewer challenge any derived record and be answered with the exact source rows —
-- the difference between a defensible repository and a pile of assertions.
CREATE TABLE IF NOT EXISTS derivation_rule_fire (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rule_id             text            NOT NULL,
    rule_pack_version   text            NOT NULL,
    report_id           uuid            NOT NULL,
    vessel_id           text            NOT NULL,
    metric              text            NOT NULL,
    fired_at            timestamptz     NOT NULL DEFAULT now(),
    window_from         timestamptz     NOT NULL,
    window_to           timestamptz     NOT NULL,
    sample_count        integer         NOT NULL,
    peak_value          double precision,
    source_event_ids    uuid[]          NOT NULL DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS idx_rulefire_rule   ON derivation_rule_fire (rule_id, fired_at DESC);
CREATE INDEX IF NOT EXISTS idx_rulefire_report ON derivation_rule_fire (report_id);

-- DML ⑦ governance: "The DML records ingestion and access events and maintains data
-- provenance/lineage" (D4.1 §4.3.5).
--
-- Note this records *what* happened, not *who* did it: subject is a component identity,
-- because authentication is not implemented. NFR-LOG-01 oversight logging of operator
-- actions cannot be satisfied without an authenticated user — see docs/open-questions.md.
CREATE TABLE IF NOT EXISTS access_audit (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    at          timestamptz     NOT NULL DEFAULT now(),
    component   text            NOT NULL,
    action      text            NOT NULL,   -- ingest | query | export | escalate | submit
    subject     text,
    resource    text,
    detail      jsonb           NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS idx_audit_time ON access_audit (at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_action ON access_audit (action, at DESC);

-- Reserved. Contract exists (contracts/system-log.v1.schema.json), no ingestion path.
CREATE TABLE IF NOT EXISTS system_log (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    timestamp       timestamptz     NOT NULL,
    severity        text            NOT NULL,
    component_id    text            NOT NULL,
    event_type      text            NOT NULL,
    message         text            NOT NULL,
    correlation_id  text,
    vessel_id       text,
    log_class       text            NOT NULL DEFAULT 'operational',
    attributes      jsonb           NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS idx_syslog_time ON system_log (timestamp DESC);

-- =====================================================================================
-- KER6 reporting view
-- =====================================================================================

-- KER6's achievement indicator is "an active repository for >500 past system failures".
-- This view is deliberately strict about what counts: state transitions are normal
-- operation and data-quality records are sensor faults, so neither is a system failure.
-- Origin is broken out so the derived/synthetic split is never hidden behind one number.
CREATE OR REPLACE VIEW ker6_repository_status AS
SELECT
    count(*) FILTER (WHERE event_class IN ('failure','anomaly'))                        AS failure_records,
    count(*) FILTER (WHERE event_class IN ('failure','anomaly') AND origin = 'derived')  AS derived_from_pilot_data,
    count(*) FILTER (WHERE event_class IN ('failure','anomaly') AND origin = 'synthetic')AS synthetic,
    count(*) FILTER (WHERE event_class IN ('failure','anomaly') AND origin = 'manual')   AS manual,
    count(*) FILTER (WHERE event_class IN ('failure','anomaly') AND origin = 'external') AS external,
    count(*) FILTER (WHERE event_class = 'state-transition')                             AS state_transitions,
    count(*) FILTER (WHERE event_class = 'data-quality')                                 AS data_quality_records,
    count(*)                                                                             AS total_records,
    count(DISTINCT vessel_id)                                                            AS vessels,
    count(DISTINCT taxonomy_code)                                                        AS distinct_failure_modes,
    min(detected_at)                                                                     AS earliest,
    max(detected_at)                                                                     AS latest
FROM failure_report;

COMMIT;

-- MDM Postgres initialisation — runs once on first container start
-- This is the MDM's own database. Counterparty data lives here, not in MSSQL.

-- ── golden_record (canonical counterparty data) ─────────────────────
CREATE TABLE IF NOT EXISTS golden_record (
    mdm_id              VARCHAR(50) PRIMARY KEY,    -- e.g. 'MDM-001' — the canonical ID
    canonical_name      VARCHAR(200) NOT NULL,
    short_code          VARCHAR(20) UNIQUE,
    credit_limit        DECIMAL(18,2),
    collateral_amount   DECIMAL(18,2) DEFAULT 0,
    currency            VARCHAR(10) DEFAULT 'JPY',
    is_active           BOOLEAN DEFAULT TRUE,
    data_steward        VARCHAR(100),               -- who owns this record
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    updated_at          TIMESTAMPTZ DEFAULT NOW()
);

-- ── incoming_record (every record from every source system) ─────────
CREATE TABLE IF NOT EXISTS incoming_record (
    record_id           SERIAL PRIMARY KEY,
    source_system       VARCHAR(50) NOT NULL,       -- 'TRADING_DESK', 'BROKER_FEED', 'INVOICE_SYSTEM'
    source_id           VARCHAR(50) NOT NULL,       -- ID in the source system
    raw_name            VARCHAR(200) NOT NULL,
    credit_limit        DECIMAL(18,2),
    received_at         TIMESTAMPTZ DEFAULT NOW(),
    match_status        VARCHAR(20) DEFAULT 'PENDING', -- PENDING, AUTO_MERGED, QUEUED, NEW
    matched_mdm_id      VARCHAR(50) REFERENCES golden_record(mdm_id),
    match_score         DECIMAL(5,2)               -- 0-100 confidence
);

-- ── stewardship_queue (conflicts for human resolution) ──────────────
CREATE TABLE IF NOT EXISTS stewardship_queue (
    queue_id            SERIAL PRIMARY KEY,
    record_a_id         INT REFERENCES incoming_record(record_id),
    record_b_id         INT REFERENCES incoming_record(record_id),
    conflict_fields     JSONB,                      -- e.g. {"credit_limit": [4000000, 5000000]}
    status              VARCHAR(20) DEFAULT 'OPEN', -- OPEN, RESOLVED
    resolved_by         VARCHAR(100),
    resolution          JSONB,                      -- final values the steward picked
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    resolved_at         TIMESTAMPTZ
);

-- ── Seed data: migrate the 3 counterparties that used to live in MSSQL ──
INSERT INTO golden_record (mdm_id, canonical_name, short_code, credit_limit, currency, data_steward) VALUES
  ('MDM-001', 'Tokyo Energy Corp',    'TEC',     5000000, 'JPY', 'kenji.tanaka'),
  ('MDM-002', 'AUS Grid Partners',    'AGP',     3000000, 'AUD', 'sarah.chen'),
  ('MDM-003', 'NZ Renewable Trust',   'NZRT',    2000000, 'NZD', 'sarah.chen')
ON CONFLICT (mdm_id) DO NOTHING;

-- ── Seed incoming_record: simulate records from multiple source systems ──
-- These give Lab 9 real data to query instead of empty tables.

-- Record 1: Broker feed sends "TEC" — exact short_code match → AUTO_MERGED
INSERT INTO incoming_record (source_system, source_id, raw_name, credit_limit, match_status, matched_mdm_id, match_score)
VALUES ('BROKER_FEED', 'BRK-8821', 'TEC', 4500000, 'AUTO_MERGED', 'MDM-001', 92.5)
ON CONFLICT DO NOTHING;

-- Record 2: Invoice system sends a long name — partial match → QUEUED for stewardship
INSERT INTO incoming_record (source_system, source_id, raw_name, credit_limit, match_status, matched_mdm_id, match_score)
VALUES ('INVOICE_SYSTEM', 'INV-2025-441', 'Tokyo Energy Corporation Ltd.', 6000000, 'QUEUED', 'MDM-001', 75.0)
ON CONFLICT DO NOTHING;

-- Record 3: Trading desk sends exact name — AUTO_MERGED
INSERT INTO incoming_record (source_system, source_id, raw_name, credit_limit, match_status, matched_mdm_id, match_score)
VALUES ('TRADING_DESK', 'TD-NZ-019', 'NZ Renewable Trust', 2000000, 'AUTO_MERGED', 'MDM-003', 98.0)
ON CONFLICT DO NOTHING;

-- Record 4: Broker feed sends unknown entity — no match → NEW (needs manual review)
INSERT INTO incoming_record (source_system, source_id, raw_name, credit_limit, match_status, matched_mdm_id, match_score)
VALUES ('BROKER_FEED', 'BRK-9102', 'Kansai Power Trading GK', 1500000, 'NEW', NULL, 12.0)
ON CONFLICT DO NOTHING;

-- Record 5: Risk system sends abbreviated name — ambiguous → QUEUED
INSERT INTO incoming_record (source_system, source_id, raw_name, credit_limit, match_status, matched_mdm_id, match_score)
VALUES ('RISK_SYSTEM', 'RSK-AU-007', 'AUS Grid Ptrs', 3200000, 'QUEUED', 'MDM-002', 68.0)
ON CONFLICT DO NOTHING;

-- Record 6: Duplicate from another broker — AUTO_MERGED
INSERT INTO incoming_record (source_system, source_id, raw_name, credit_limit, match_status, matched_mdm_id, match_score)
VALUES ('BROKER_FEED', 'BRK-9205', 'AGP', 3000000, 'AUTO_MERGED', 'MDM-002', 95.0)
ON CONFLICT DO NOTHING;

-- ── Seed stewardship_queue: conflicts waiting for human resolution ──

-- Conflict 1: Invoice system record vs golden record — credit limit mismatch
INSERT INTO stewardship_queue (record_a_id, record_b_id, conflict_fields, status)
VALUES (
    (SELECT record_id FROM incoming_record WHERE source_id = 'INV-2025-441' LIMIT 1),
    NULL,
    '{"credit_limit": {"golden": 5000000, "incoming": 6000000}, "name": {"golden": "Tokyo Energy Corp", "incoming": "Tokyo Energy Corporation Ltd."}}',
    'OPEN'
);

-- Conflict 2: Risk system record vs golden record — credit limit + name mismatch
INSERT INTO stewardship_queue (record_a_id, record_b_id, conflict_fields, status)
VALUES (
    (SELECT record_id FROM incoming_record WHERE source_id = 'RSK-AU-007' LIMIT 1),
    NULL,
    '{"credit_limit": {"golden": 3000000, "incoming": 3200000}, "name": {"golden": "AUS Grid Partners", "incoming": "AUS Grid Ptrs"}}',
    'OPEN'
);

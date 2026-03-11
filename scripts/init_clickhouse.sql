-- ClickHouse initialisation — runs once on first container start

CREATE DATABASE IF NOT EXISTS etrm;

-- ── market_data ───────────────────────────────────────────────────
-- Append-only. Use FINAL or argMax to get latest value per slot.
CREATE TABLE IF NOT EXISTS etrm.market_data (
    value_date          Date,
    value_datetime      DateTime,
    issue_datetime      DateTime,
    area_id             UInt32,
    price               Float64,
    volume              Float64,
    source              String,
    currency            String
) ENGINE = ReplacingMergeTree(issue_datetime)
ORDER BY (area_id, value_datetime, issue_datetime)
PARTITION BY toYYYYMM(value_datetime);

-- ── mtm_curve ────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS etrm.mtm_curve (
    curve_id            UInt32,
    value_date          Date,
    value_datetime      DateTime,
    issue_datetime      DateTime,
    price               Float64,
    source              String
) ENGINE = ReplacingMergeTree(issue_datetime)
ORDER BY (curve_id, value_datetime, issue_datetime)
PARTITION BY toYYYYMM(value_datetime);

-- ── transaction_exploded ──────────────────────────────────────────
-- Each trade broken into 30-min delivery slots.
-- Query with FINAL to get deduplicated latest snapshot.
CREATE TABLE IF NOT EXISTS etrm.transaction_exploded (
    trade_id            UInt32,
    component_id        UInt32,
    unique_id           String,
    interval_start      DateTime,
    interval_end        DateTime,
    quantity            Float64,
    price               Float64,
    settle_price        Nullable(Float64),
    mtm_price           Nullable(Float64),
    realized_pnl        Nullable(Float64),
    unrealized_pnl      Nullable(Float64),
    area_id             UInt32,
    currency            String,
    issue_datetime      DateTime
) ENGINE = ReplacingMergeTree(issue_datetime)
ORDER BY (trade_id, component_id, interval_start, issue_datetime)
PARTITION BY toYYYYMM(interval_start);

-- ── ppa_production ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS etrm.ppa_production (
    ppa_id              UInt32,
    production_date     Date,
    interval_start      DateTime,
    interval_end        DateTime,
    actual_mwh          Float64,
    forecast_mwh        Float64,
    price               Float64,
    issue_datetime      DateTime
) ENGINE = ReplacingMergeTree(issue_datetime)
ORDER BY (ppa_id, interval_start, issue_datetime)
PARTITION BY toYYYYMM(production_date);

-- ── Seed 30 days of synthetic market data ─────────────────────────
-- Strategy: generate 4320 rows (1440 slots × 3 areas) using numbers(4320)
-- area = (n % 3) + 1,  slot = base + floor(n/3) * 30 minutes
-- Use base_price array indexed by area_id to avoid CASE with non-const rand()
-- base prices: area1=11 (JEPX JPY/kWh), area2=80 (NEM AUD/MWh), area3=60 (NZEM NZD/MWh)
INSERT INTO etrm.market_data
SELECT
    toDate(slot)                                                            AS value_date,
    slot                                                                    AS value_datetime,
    now()                                                                   AS issue_datetime,
    area_id,
    [11.0, 80.0, 60.0][area_id] + (rand() % 1000) / 200.0                 AS price,
    [500.0, 300.0, 200.0][area_id] + (rand() % 100)                       AS volume,
    'SEED'                                                                  AS source,
    ['JPY', 'AUD', 'NZD'][area_id]                                         AS currency
FROM (
    SELECT
        toUInt8((number % 3) + 1)                                                   AS area_id,
        toDateTime('2025-01-01 00:00:00') + INTERVAL (intDiv(number, 3) * 30) MINUTE AS slot
    FROM numbers(4320)
) AS src;

-- Seed MTM curves
INSERT INTO etrm.mtm_curve
SELECT
    toUInt32(area_id)                                                       AS curve_id,
    toDate(slot)                                                            AS value_date,
    slot                                                                    AS value_datetime,
    now()                                                                   AS issue_datetime,
    [11.0, 80.0, 60.0][area_id] + (rand() % 1000) / 200.0                 AS price,
    'SEED'                                                                  AS source
FROM (
    SELECT
        toUInt8((number % 3) + 1)                                                   AS area_id,
        toDateTime('2025-01-01 00:00:00') + INTERVAL (intDiv(number, 3) * 30) MINUTE AS slot
    FROM numbers(4320)
) AS src;

SELECT 'ClickHouse init complete' AS status;

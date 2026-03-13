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

-- ── Seed 120 days of synthetic market data (Jan 1 – Apr 30) ──────────
-- Strategy: generate 17280 rows (5760 slots × 3 areas) using numbers(17280)
-- Covers Jan-Apr to align with trade delivery periods (Feb-Apr).
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
    FROM numbers(17280)
) AS src;

-- Seed MTM curves (Jan-Apr, matching market_data coverage)
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
    FROM numbers(17280)
) AS src;

-- ── Seed transaction_exploded for all 5 trades ─────────────────────
-- Mirrors the MSSQL seed trades. Each trade is exploded into 30-min slots
-- for its delivery period. Market prices from market_data are used as mtm_price.
-- Past intervals (before 2025-02-15) get settle_price + realized_pnl.
-- Future intervals get mtm_price + unrealized_pnl.

-- Trade 1: TRADE-JP-001, component_id=1, area_id=1 (JEPX), STANDARD, 100MW @ 11.50 JPY
-- Delivery: 2025-02-01 to 2025-02-28 = 28 days × 48 slots = 1344 rows
INSERT INTO etrm.transaction_exploded
SELECT
    1                                                                   AS trade_id,
    1                                                                   AS component_id,
    'TRADE-JP-001'                                                      AS unique_id,
    slot                                                                AS interval_start,
    slot + INTERVAL 30 MINUTE                                           AS interval_end,
    100.0                                                               AS quantity,
    11.50                                                               AS price,
    -- Past intervals get a settle price (simulate exchange publishing actuals)
    if(slot < toDateTime('2025-02-15 00:00:00'),
       11.50 + (rand() % 400) / 200.0 - 1.0,
       NULL)                                                            AS settle_price,
    -- All intervals get an MTM price
    11.50 + (rand() % 600) / 200.0 - 1.5                               AS mtm_price,
    -- Realized P&L for settled intervals
    if(slot < toDateTime('2025-02-15 00:00:00'),
       100.0 * ((11.50 + (rand() % 400) / 200.0 - 1.0) - 11.50),
       NULL)                                                            AS realized_pnl,
    -- Unrealized P&L for open intervals
    if(slot >= toDateTime('2025-02-15 00:00:00'),
       100.0 * ((11.50 + (rand() % 600) / 200.0 - 1.5) - 11.50),
       NULL)                                                            AS unrealized_pnl,
    1                                                                   AS area_id,
    'JPY'                                                               AS currency,
    now()                                                               AS issue_datetime
FROM (
    SELECT toDateTime('2025-02-01 00:00:00') + INTERVAL (number * 30) MINUTE AS slot
    FROM numbers(1344)
) AS src;

-- Trade 2: TRADE-AU-001, component_id=2, area_id=2 (NEM), CONSTANT 07:00-17:00, 50MW @ 82.00 AUD
-- Delivery: 2025-02-01 to 2025-02-28, weekdays only, 07:00-17:00 = 20 slots/day
-- ~20 weekdays × 20 slots = ~400 rows. Simplified: generate all slots, filter to business hours weekdays.
INSERT INTO etrm.transaction_exploded
SELECT
    2                                                                   AS trade_id,
    2                                                                   AS component_id,
    'TRADE-AU-001'                                                      AS unique_id,
    slot                                                                AS interval_start,
    slot + INTERVAL 30 MINUTE                                           AS interval_end,
    50.0                                                                AS quantity,
    82.00                                                               AS price,
    if(slot < toDateTime('2025-02-15 00:00:00'),
       82.00 + (rand() % 1000) / 100.0 - 5.0,
       NULL)                                                            AS settle_price,
    82.00 + (rand() % 1500) / 100.0 - 7.5                              AS mtm_price,
    if(slot < toDateTime('2025-02-15 00:00:00'),
       50.0 * ((82.00 + (rand() % 1000) / 100.0 - 5.0) - 82.00),
       NULL)                                                            AS realized_pnl,
    if(slot >= toDateTime('2025-02-15 00:00:00'),
       50.0 * ((82.00 + (rand() % 1500) / 100.0 - 7.5) - 82.00),
       NULL)                                                            AS unrealized_pnl,
    2                                                                   AS area_id,
    'AUD'                                                               AS currency,
    now()                                                               AS issue_datetime
FROM (
    SELECT toDateTime('2025-02-01 00:00:00') + INTERVAL (number * 30) MINUTE AS slot
    FROM numbers(1344)
) AS src
WHERE toDayOfWeek(slot) <= 5                        -- weekdays only
  AND toHour(slot) >= 7 AND toHour(slot) < 17;      -- business hours

-- Trade 3: TRADE-NZ-001, component_id=3, area_id=3 (NZEM), VARIABLE 06:00-22:00, 75MW @ 58.50 NZD
INSERT INTO etrm.transaction_exploded
SELECT
    3                                                                   AS trade_id,
    3                                                                   AS component_id,
    'TRADE-NZ-001'                                                      AS unique_id,
    slot                                                                AS interval_start,
    slot + INTERVAL 30 MINUTE                                           AS interval_end,
    75.0                                                                AS quantity,
    58.50                                                               AS price,
    if(slot < toDateTime('2025-02-15 00:00:00'),
       58.50 + (rand() % 800) / 100.0 - 4.0,
       NULL)                                                            AS settle_price,
    58.50 + (rand() % 1200) / 100.0 - 6.0                              AS mtm_price,
    if(slot < toDateTime('2025-02-15 00:00:00'),
       75.0 * ((58.50 + (rand() % 800) / 100.0 - 4.0) - 58.50),
       NULL)                                                            AS realized_pnl,
    if(slot >= toDateTime('2025-02-15 00:00:00'),
       75.0 * ((58.50 + (rand() % 1200) / 100.0 - 6.0) - 58.50),
       NULL)                                                            AS unrealized_pnl,
    3                                                                   AS area_id,
    'NZD'                                                               AS currency,
    now()                                                               AS issue_datetime
FROM (
    SELECT toDateTime('2025-02-01 00:00:00') + INTERVAL (number * 30) MINUTE AS slot
    FROM numbers(1344)
) AS src
WHERE toHour(slot) >= 6 AND toHour(slot) < 22;      -- 06:00-22:00 window

-- Trade 4: TRADE-JP-002, component_id=4, area_id=1 (JEPX), STANDARD, 200MW @ 12.00 JPY
-- Delivery: 2025-04-01 to 2025-04-30 = 30 days × 48 = 1440 slots (all future)
INSERT INTO etrm.transaction_exploded
SELECT
    4                                                                   AS trade_id,
    4                                                                   AS component_id,
    'TRADE-JP-002'                                                      AS unique_id,
    slot                                                                AS interval_start,
    slot + INTERVAL 30 MINUTE                                           AS interval_end,
    200.0                                                               AS quantity,
    12.00                                                               AS price,
    NULL                                                                AS settle_price,
    12.00 + (rand() % 800) / 200.0 - 2.0                               AS mtm_price,
    NULL                                                                AS realized_pnl,
    200.0 * ((12.00 + (rand() % 800) / 200.0 - 2.0) - 12.00)          AS unrealized_pnl,
    1                                                                   AS area_id,
    'JPY'                                                               AS currency,
    now()                                                               AS issue_datetime
FROM (
    SELECT toDateTime('2025-04-01 00:00:00') + INTERVAL (number * 30) MINUTE AS slot
    FROM numbers(1440)
) AS src;

-- Trade 5: TRADE-AU-002, component_id=5, area_id=2 (NEM), CONSTANT 07:00-17:00, 80MW @ 85.00 AUD
-- Delivery: 2025-04-01 to 2025-04-30 (all future)
INSERT INTO etrm.transaction_exploded
SELECT
    5                                                                   AS trade_id,
    5                                                                   AS component_id,
    'TRADE-AU-002'                                                      AS unique_id,
    slot                                                                AS interval_start,
    slot + INTERVAL 30 MINUTE                                           AS interval_end,
    80.0                                                                AS quantity,
    85.00                                                               AS price,
    NULL                                                                AS settle_price,
    85.00 + (rand() % 2000) / 100.0 - 10.0                             AS mtm_price,
    NULL                                                                AS realized_pnl,
    80.0 * ((85.00 + (rand() % 2000) / 100.0 - 10.0) - 85.00)         AS unrealized_pnl,
    2                                                                   AS area_id,
    'AUD'                                                               AS currency,
    now()                                                               AS issue_datetime
FROM (
    SELECT toDateTime('2025-04-01 00:00:00') + INTERVAL (number * 30) MINUTE AS slot
    FROM numbers(1440)
) AS src
WHERE toDayOfWeek(slot) <= 5
  AND toHour(slot) >= 7 AND toHour(slot) < 17;

-- ── Seed invoice data matching MSSQL trades ─────────────────────────
-- Insert a second version of some Trade 1 intervals to demonstrate FINAL/dedup
-- This simulates a price update that happened 1 day after initial load
INSERT INTO etrm.transaction_exploded
SELECT
    1                                                                   AS trade_id,
    1                                                                   AS component_id,
    'TRADE-JP-001'                                                      AS unique_id,
    slot                                                                AS interval_start,
    slot + INTERVAL 30 MINUTE                                           AS interval_end,
    100.0                                                               AS quantity,
    11.50                                                               AS price,
    if(slot < toDateTime('2025-02-15 00:00:00'),
       11.50 + (rand() % 300) / 200.0 - 0.5,
       NULL)                                                            AS settle_price,
    11.50 + (rand() % 500) / 200.0 - 1.0                               AS mtm_price,
    if(slot < toDateTime('2025-02-15 00:00:00'),
       100.0 * ((11.50 + (rand() % 300) / 200.0 - 0.5) - 11.50),
       NULL)                                                            AS realized_pnl,
    if(slot >= toDateTime('2025-02-15 00:00:00'),
       100.0 * ((11.50 + (rand() % 500) / 200.0 - 1.0) - 11.50),
       NULL)                                                            AS unrealized_pnl,
    1                                                                   AS area_id,
    'JPY'                                                               AS currency,
    now() + INTERVAL 1 DAY                                              AS issue_datetime
FROM (
    SELECT toDateTime('2025-02-01 00:00:00') + INTERVAL (number * 30) MINUTE AS slot
    FROM numbers(480)   -- first 10 days only (480 slots) to show partial update
) AS src;

SELECT 'ClickHouse init complete' AS status;

-- Power BI Reporting Views — ClickHouse
-- Run against ClickHouse HTTP interface (port 8123) after init_clickhouse.sql
-- Execute via: curl -X POST http://localhost:8123 --data-binary @powerbi_views_clickhouse.sql
-- Or paste each block into DBeaver connected to ClickHouse.
--
-- NOTE: ClickHouse "views" are lazy — they re-run the query each time.
-- For Power BI Import mode this is fine. For large datasets use MATERIALIZED VIEW.

-- ─────────────────────────────────────────────────────────────────────────────
-- vw_pnl_by_trade
-- P&L summary per trade, deduplicated via FINAL.
-- This is the main P&L report view — one row per trade+component+currency.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW etrm.vw_pnl_by_trade AS
SELECT
    trade_id,
    component_id,
    unique_id                               AS trade_ref,
    currency,
    area_id,
    CASE area_id
        WHEN 1 THEN 'JEPX'
        WHEN 2 THEN 'NEM'
        WHEN 3 THEN 'NZEM'
        ELSE 'UNKNOWN'
    END                                     AS market_area,

    -- Volume
    COUNT(*)                                AS interval_count,
    SUM(quantity)                           AS total_quantity_mw,

    -- Contracted value
    SUM(quantity * price)                   AS total_contracted_value,
    AVG(price)                              AS avg_contracted_price,

    -- P&L split
    SUM(COALESCE(realized_pnl, 0))         AS total_realized_pnl,
    SUM(COALESCE(unrealized_pnl, 0))       AS total_unrealized_pnl,
    SUM(COALESCE(realized_pnl, 0))
        + SUM(COALESCE(unrealized_pnl, 0)) AS total_pnl,

    -- Delivery window
    MIN(interval_start)                     AS delivery_start,
    MAX(interval_end)                       AS delivery_end,

    -- How many slots are settled vs pending
    countIf(settle_price IS NOT NULL)       AS settled_intervals,
    countIf(settle_price IS NULL)           AS pending_intervals,

    -- Latest snapshot timestamp
    MAX(issue_datetime)                     AS last_updated

FROM etrm.transaction_exploded FINAL
GROUP BY
    trade_id,
    component_id,
    unique_id,
    currency,
    area_id;


-- ─────────────────────────────────────────────────────────────────────────────
-- vw_pnl_daily
-- Daily P&L rollup across all trades. Good for a time-series line chart.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW etrm.vw_pnl_daily AS
SELECT
    toDate(interval_start)                  AS delivery_date,
    area_id,
    CASE area_id
        WHEN 1 THEN 'JEPX'
        WHEN 2 THEN 'NEM'
        WHEN 3 THEN 'NZEM'
        ELSE 'UNKNOWN'
    END                                     AS market_area,
    currency,
    SUM(COALESCE(realized_pnl, 0))         AS daily_realized_pnl,
    SUM(COALESCE(unrealized_pnl, 0))       AS daily_unrealized_pnl,
    SUM(COALESCE(realized_pnl, 0))
        + SUM(COALESCE(unrealized_pnl, 0)) AS daily_total_pnl,
    SUM(quantity)                           AS total_mw_delivered,
    COUNT(DISTINCT trade_id)                AS active_trade_count
FROM etrm.transaction_exploded FINAL
GROUP BY
    toDate(interval_start),
    area_id,
    currency
ORDER BY delivery_date, area_id;


-- ─────────────────────────────────────────────────────────────────────────────
-- vw_market_prices_latest
-- Latest price per half-hour slot per area, using argMax to deduplicate.
-- Use this for price curve charts in Power BI.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW etrm.vw_market_prices_latest AS
SELECT
    value_datetime,
    toDate(value_datetime)                  AS value_date,
    area_id,
    CASE area_id
        WHEN 1 THEN 'JEPX'
        WHEN 2 THEN 'NEM'
        WHEN 3 THEN 'NZEM'
        ELSE 'UNKNOWN'
    END                                     AS market_area,
    argMax(price, issue_datetime)           AS latest_price,
    argMax(volume, issue_datetime)          AS latest_volume,
    argMax(currency, issue_datetime)        AS currency,
    max(issue_datetime)                     AS as_of
FROM etrm.market_data
GROUP BY
    value_datetime,
    area_id
ORDER BY value_datetime, area_id;


-- ─────────────────────────────────────────────────────────────────────────────
-- vw_mtm_curve_latest
-- Latest MTM curve price per slot, deduplicated via argMax.
-- Used to show forward curve vs contracted price.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW etrm.vw_mtm_curve_latest AS
SELECT
    curve_id,
    value_datetime,
    toDate(value_datetime)                  AS value_date,
    argMax(price, issue_datetime)           AS mtm_price,
    argMax(source, issue_datetime)          AS source,
    max(issue_datetime)                     AS as_of
FROM etrm.mtm_curve
GROUP BY
    curve_id,
    value_datetime
ORDER BY curve_id, value_datetime;


-- ─────────────────────────────────────────────────────────────────────────────
-- vw_trade_intervals_flat
-- One row per half-hour slot per trade component — the most granular view.
-- Use this for drill-through in Power BI (trader asks: "show me every slot").
-- FINAL ensures deduplication of ReplacingMergeTree.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW etrm.vw_trade_intervals_flat AS
SELECT
    trade_id,
    component_id,
    unique_id                               AS trade_ref,
    interval_start,
    interval_end,
    toDate(interval_start)                  AS delivery_date,
    toHour(interval_start)                  AS delivery_hour,
    area_id,
    CASE area_id
        WHEN 1 THEN 'JEPX'
        WHEN 2 THEN 'NEM'
        WHEN 3 THEN 'NZEM'
        ELSE 'UNKNOWN'
    END                                     AS market_area,
    currency,
    quantity,
    price                                   AS contracted_price,
    settle_price,
    mtm_price,
    COALESCE(settle_price, mtm_price)       AS valuation_price,
    realized_pnl,
    unrealized_pnl,
    COALESCE(realized_pnl, unrealized_pnl) AS interval_pnl,

    -- Flags for filtering in Power BI
    if(settle_price IS NOT NULL, 1, 0)     AS is_settled,
    if(interval_start < now(), 1, 0)       AS is_past,

    issue_datetime                          AS snapshot_time
FROM etrm.transaction_exploded FINAL;


SELECT 'ClickHouse Power BI views created successfully' AS status;

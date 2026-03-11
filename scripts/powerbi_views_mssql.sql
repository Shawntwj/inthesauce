-- Power BI Reporting Views — MSSQL (Azure SQL Edge)
-- Run this once against the etrm database after init_mssql.sql
-- These views are flat/denormalized so Power BI can use them without joins.

USE etrm;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- vw_trade_blotter
-- One row per trade component. The main "trade blotter" view for traders.
-- Shows all key trade details plus counterparty info in a single flat table.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER VIEW vw_trade_blotter AS
SELECT
    t.trade_id,
    t.unique_id                                         AS trade_ref,
    t.trade_at_utc                                      AS trade_date,
    t.is_active,
    t.is_hypothetical,
    t.book_id,
    t.trader_id,

    -- Counterparty
    cp.counterparty_id,
    cp.name                                             AS counterparty_name,
    cp.short_code                                       AS counterparty_code,
    cp.credit_limit,

    -- Component
    tc.component_id,
    tc.area_id,
    CASE tc.area_id
        WHEN 1 THEN 'JEPX'
        WHEN 2 THEN 'NEM'
        WHEN 3 THEN 'NZEM'
        ELSE 'UNKNOWN'
    END                                                 AS market_area,
    tc.settlement_mode,                                 -- PHYSICAL / FINANCIAL
    tc.product_type,                                    -- STANDARD / CONSTANT / VARIABLE
    tc.commodity_type,
    tc.price_denominator                                AS currency,
    tc.quantity                                         AS quantity_mw,
    tc.price                                            AS contracted_price,
    tc.quantity * tc.price                              AS notional_value,
    tc.start_date                                       AS delivery_start,
    tc.end_date                                         AS delivery_end,
    DATEDIFF(DAY, tc.start_date, tc.end_date) + 1      AS delivery_days,

    -- Delivery profile
    dp.profile_name,
    dp.start_time                                       AS delivery_window_start,
    dp.end_time                                         AS delivery_window_end,
    dp.includes_weekends,
    dp.includes_holidays,

    t.created_at,
    t.updated_at
FROM trade t
JOIN counterparty      cp ON cp.counterparty_id = t.counterparty_id
JOIN trade_component   tc ON tc.trade_id        = t.trade_id
JOIN delivery_profile  dp ON dp.delivery_profile_id = tc.delivery_profile_id;
GO


-- ─────────────────────────────────────────────────────────────────────────────
-- vw_counterparty_exposure
-- Aggregated exposure per counterparty vs credit limit.
-- Used for the credit risk / exposure dashboard.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER VIEW vw_counterparty_exposure AS
SELECT
    cp.counterparty_id,
    cp.name                                             AS counterparty_name,
    cp.short_code                                       AS counterparty_code,
    cp.credit_limit,
    cp.collateral_amount,
    cp.credit_limit - cp.collateral_amount              AS net_credit_limit,

    COUNT(DISTINCT t.trade_id)                          AS open_trade_count,

    -- Total notional of active, non-hypothetical trades
    SUM(
        CASE WHEN t.is_active = 1 AND t.is_hypothetical = 0
             THEN tc.quantity * tc.price
             ELSE 0
        END
    )                                                   AS total_exposure,

    cp.credit_limit - SUM(
        CASE WHEN t.is_active = 1 AND t.is_hypothetical = 0
             THEN tc.quantity * tc.price
             ELSE 0
        END
    )                                                   AS remaining_headroom,

    -- Simple utilisation % for a gauge visual
    CAST(
        SUM(
            CASE WHEN t.is_active = 1 AND t.is_hypothetical = 0
                 THEN tc.quantity * tc.price
                 ELSE 0
            END
        ) * 100.0 / NULLIF(cp.credit_limit, 0)
    AS DECIMAL(5,2))                                    AS utilisation_pct

FROM counterparty cp
LEFT JOIN trade          t  ON t.counterparty_id = cp.counterparty_id
LEFT JOIN trade_component tc ON tc.trade_id      = t.trade_id
WHERE cp.is_active = 1
GROUP BY
    cp.counterparty_id,
    cp.name,
    cp.short_code,
    cp.credit_limit,
    cp.collateral_amount;
GO


-- ─────────────────────────────────────────────────────────────────────────────
-- vw_invoice_status
-- Flat invoice view joined to trade and counterparty.
-- Used for invoice matching / settlement dashboard.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER VIEW vw_invoice_status AS
SELECT
    i.invoice_id,
    i.invoice_number,
    i.invoice_date,
    i.due_date,
    i.amount,
    i.currency,
    i.status,                                           -- PENDING / MATCHED / ERROR
    i.matched_amount,
    i.match_status,                                     -- FULL / PARTIAL / MISMATCH
    i.amount - ISNULL(i.matched_amount, 0)             AS unmatched_amount,

    -- Trade details
    t.trade_id,
    t.unique_id                                         AS trade_ref,
    t.trade_at_utc                                      AS trade_date,
    t.book_id,

    -- Counterparty
    cp.name                                             AS counterparty_name,
    cp.short_code                                       AS counterparty_code,

    -- Component
    tc.area_id,
    CASE tc.area_id
        WHEN 1 THEN 'JEPX'
        WHEN 2 THEN 'NEM'
        WHEN 3 THEN 'NZEM'
        ELSE 'UNKNOWN'
    END                                                 AS market_area,
    tc.settlement_mode,
    tc.product_type,

    i.created_at,

    -- Age in days (useful for overdue tracking)
    DATEDIFF(DAY, i.due_date, GETUTCDATE())            AS days_overdue

FROM invoice i
JOIN trade          t  ON t.trade_id         = i.trade_id
JOIN counterparty   cp ON cp.counterparty_id = t.counterparty_id
LEFT JOIN trade_component tc ON tc.component_id = i.component_id;
GO


-- ─────────────────────────────────────────────────────────────────────────────
-- vw_book_summary
-- Aggregated by book_id. Useful for book-level P&L rollup page.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER VIEW vw_book_summary AS
SELECT
    t.book_id,
    CASE tc.area_id
        WHEN 1 THEN 'JEPX'
        WHEN 2 THEN 'NEM'
        WHEN 3 THEN 'NZEM'
        ELSE 'UNKNOWN'
    END                                                 AS market_area,
    tc.settlement_mode,
    tc.price_denominator                                AS currency,
    COUNT(DISTINCT t.trade_id)                          AS trade_count,
    SUM(tc.quantity)                                    AS total_quantity_mw,
    SUM(tc.quantity * tc.price)                         AS total_notional,
    AVG(tc.price)                                       AS avg_price,
    MIN(tc.start_date)                                  AS earliest_delivery,
    MAX(tc.end_date)                                    AS latest_delivery
FROM trade t
JOIN trade_component tc ON tc.trade_id = t.trade_id
WHERE t.is_active = 1
GROUP BY
    t.book_id,
    tc.area_id,
    tc.settlement_mode,
    tc.price_denominator;
GO

PRINT 'Power BI MSSQL views created successfully.';
GO

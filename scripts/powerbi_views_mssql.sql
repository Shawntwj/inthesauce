-- Power BI Reporting Views — MSSQL (Azure SQL Edge)
-- Run this once against the etrm database after init_mssql.sql
-- These views are flat/denormalized so Power BI can use them without joins.
--
-- NOTE: Counterparty data lives in MDM Postgres (golden_record table).
-- These views include counterparty_mdm_id so you can join in your BI tool
-- or query the MDM API for counterparty details.

USE etrm;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- vw_trade_blotter
-- One row per trade component. The main "trade blotter" view for traders.
-- counterparty_mdm_id references the MDM golden_record — join in BI tool
-- or use the MDM Postgres datasource for counterparty details.
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

    -- Counterparty (MDM reference)
    t.counterparty_mdm_id,

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
JOIN trade_component   tc ON tc.trade_id        = t.trade_id
JOIN delivery_profile  dp ON dp.delivery_profile_id = tc.delivery_profile_id;
GO


-- ─────────────────────────────────────────────────────────────────────────────
-- vw_counterparty_exposure
-- Aggregated exposure per counterparty MDM ID.
-- Join with MDM Postgres golden_record for counterparty name/credit limit.
-- Credit limit is now managed by MDM, so this view only shows ETRM-side exposure.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER VIEW vw_counterparty_exposure AS
SELECT
    t.counterparty_mdm_id,

    COUNT(DISTINCT t.trade_id)                          AS open_trade_count,

    -- Total notional of active, non-hypothetical trades
    SUM(
        CASE WHEN t.is_active = 1 AND t.is_hypothetical = 0
             THEN tc.quantity * tc.price
             ELSE 0
        END
    )                                                   AS total_exposure

FROM trade t
LEFT JOIN trade_component tc ON tc.trade_id = t.trade_id
WHERE t.is_active = 1
GROUP BY
    t.counterparty_mdm_id;
GO


-- ─────────────────────────────────────────────────────────────────────────────
-- vw_invoice_status
-- Flat invoice view joined to trade.
-- counterparty_mdm_id included for MDM lookup.
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

    -- Counterparty (MDM reference)
    t.counterparty_mdm_id,

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

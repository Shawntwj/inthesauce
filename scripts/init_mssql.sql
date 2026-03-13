-- MSSQL initialisation — runs once on first container start
-- Azure SQL Edge compatible (ARM64)

-- Create the database
IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = 'etrm')
BEGIN
    CREATE DATABASE etrm;
END
GO

USE etrm;
GO

-- NOTE: counterparty table has been moved to MDM Postgres.
-- The ETRM trade service fetches counterparty/credit data from the MDM API.
-- See scripts/init_mdm_postgres.sql for the golden_record schema.

-- ── delivery_profile ──────────────────────────────────────────────
CREATE TABLE delivery_profile (
    delivery_profile_id INT IDENTITY(1,1) PRIMARY KEY,
    profile_name        VARCHAR(100) NOT NULL,
    product_type        VARCHAR(20) NOT NULL,   -- STANDARD, CONSTANT, VARIABLE
    interval_minutes    INT NOT NULL DEFAULT 30,
    start_time          TIME,
    end_time            TIME,
    includes_weekends   BIT DEFAULT 0,
    includes_holidays   BIT DEFAULT 0
);
GO

-- ── trade ─────────────────────────────────────────────────────────
CREATE TABLE trade (
    trade_id            INT IDENTITY(1,1) PRIMARY KEY,
    unique_id           VARCHAR(50) UNIQUE NOT NULL,
    total_quantity      DECIMAL(18,4),
    trade_at_utc        DATETIME2 NOT NULL,
    is_active           BIT DEFAULT 1,
    is_hypothetical     BIT DEFAULT 0,
    counterparty_mdm_id VARCHAR(50) NOT NULL,  -- references MDM golden_record.mdm_id (e.g. 'MDM-001')
    broker_id           INT,
    clearer_id          INT,
    trader_id           INT NOT NULL DEFAULT 1,
    initiator_id        INT,
    source_id           INT,
    invoice_spec_id     INT,
    book_id             INT NOT NULL DEFAULT 1,
    perspective_id      INT,
    cascade_spec_id     INT,
    created_at          DATETIME2 DEFAULT GETUTCDATE(),
    updated_at          DATETIME2 DEFAULT GETUTCDATE()
);
GO

-- ── trade_component ───────────────────────────────────────────────
CREATE TABLE trade_component (
    component_id        INT IDENTITY(1,1) PRIMARY KEY,
    trade_id            INT NOT NULL REFERENCES trade(trade_id),
    area_id             INT NOT NULL,           -- 1=JEPX, 2=NEM, 3=NZEM
    delivery_profile_id INT NOT NULL REFERENCES delivery_profile(delivery_profile_id),
    settlement_mode     VARCHAR(20) NOT NULL,   -- PHYSICAL, FINANCIAL
    price_denominator   VARCHAR(10) NOT NULL,   -- JPY, AUD, NZD, USD
    commodity_type      VARCHAR(20) DEFAULT 'POWER',
    product_type        VARCHAR(20) NOT NULL,   -- STANDARD, CONSTANT, VARIABLE
    quantity            DECIMAL(18,4) NOT NULL,
    price               DECIMAL(18,6) NOT NULL,
    start_date          DATE NOT NULL,
    end_date            DATE NOT NULL,
    created_at          DATETIME2 DEFAULT GETUTCDATE()
);
GO

-- ── curve (MTM reference metadata) ───────────────────────────────
CREATE TABLE curve (
    curve_id            INT IDENTITY(1,1) PRIMARY KEY,
    curve_name          VARCHAR(100) NOT NULL,
    curve_type          VARCHAR(20) NOT NULL,   -- MTM, MODEL, SETTLE
    area_id             INT NOT NULL,
    source              VARCHAR(50),
    is_active           BIT DEFAULT 1
);
GO

-- ── invoice ───────────────────────────────────────────────────────
CREATE TABLE invoice (
    invoice_id          INT IDENTITY(1,1) PRIMARY KEY,
    trade_id            INT NOT NULL REFERENCES trade(trade_id),
    component_id        INT REFERENCES trade_component(component_id),
    invoice_number      VARCHAR(50) UNIQUE,
    amount              DECIMAL(18,2) NOT NULL,
    currency            VARCHAR(10) NOT NULL,
    invoice_date        DATE NOT NULL,
    due_date            DATE NOT NULL,
    status              VARCHAR(20) DEFAULT 'PENDING',
    matched_amount      DECIMAL(18,2),
    match_status        VARCHAR(20),
    created_at          DATETIME2 DEFAULT GETUTCDATE()
);
GO

-- ── half_hour_intervals (calendar helper) ────────────────────────
-- Generate 2024-01-01 to 2026-12-31 in 30-min slots (~52,560 rows)
WITH dates AS (
    SELECT CAST('2024-01-01 00:00:00' AS DATETIME2) AS slot
    UNION ALL
    SELECT DATEADD(MINUTE, 30, slot)
    FROM dates
    WHERE slot < '2026-12-31 23:30:00'
)
SELECT
    slot                                        AS interval_start,
    DATEADD(MINUTE, 30, slot)                  AS interval_end,
    CAST(slot AS DATE)                         AS trade_date,
    CASE WHEN DATEPART(WEEKDAY, slot) IN (1,7) THEN 1 ELSE 0 END AS is_weekend,
    CAST(0 AS BIT)                             AS is_holiday
INTO half_hour_intervals
FROM dates
OPTION (MAXRECURSION 0);
GO

ALTER TABLE half_hour_intervals
    ADD CONSTRAINT PK_half_hour PRIMARY KEY (interval_start);
GO

-- ── Seed data ─────────────────────────────────────────────────────
-- NOTE: Counterparties now live in MDM Postgres (golden_record table).
-- Trades reference MDM IDs: MDM-001 (Tokyo Energy Corp), MDM-002 (AUS Grid Partners), MDM-003 (NZ Renewable Trust)

-- Delivery profiles
INSERT INTO delivery_profile (profile_name, product_type, interval_minutes, start_time, end_time)
VALUES
    ('JEPX Standard 24H',     'STANDARD',  30, NULL,    NULL),
    ('NEM Business Hours',    'CONSTANT',  30, '07:00', '17:00'),
    ('NZEM Variable Custom',  'VARIABLE',  30, '06:00', '22:00');

-- Curves
INSERT INTO curve (curve_name, curve_type, area_id, source)
VALUES
    ('JEPX Spot MTM',    'MTM',    1, 'EXCHANGE'),
    ('NEM Futures MTM',  'MTM',    2, 'EXCHANGE'),
    ('NZEM Spot MTM',    'MTM',    3, 'EXCHANGE'),
    ('JEPX In-House',    'MODEL',  1, 'IN_HOUSE'),
    ('NEM In-House',     'MODEL',  2, 'IN_HOUSE');

-- Sample trades (counterparty_mdm_id references MDM golden_record)
INSERT INTO trade (unique_id, total_quantity, trade_at_utc, counterparty_mdm_id, trader_id, book_id)
VALUES
    ('TRADE-JP-001', 100.0, '2025-01-15 02:00:00', 'MDM-001', 1, 1),
    ('TRADE-AU-001',  50.0, '2025-01-20 00:00:00', 'MDM-002', 1, 1),
    ('TRADE-NZ-001',  75.0, '2025-02-01 00:00:00', 'MDM-003', 1, 2),
    ('TRADE-JP-002', 200.0, '2025-03-01 03:00:00', 'MDM-001', 1, 1),
    ('TRADE-AU-002',  80.0, '2025-03-10 00:00:00', 'MDM-002', 1, 2);

-- Trade components
INSERT INTO trade_component
    (trade_id, area_id, delivery_profile_id, settlement_mode, price_denominator, product_type, quantity, price, start_date, end_date)
VALUES
    (1, 1, 1, 'FINANCIAL', 'JPY', 'STANDARD',  100.0, 11.50, '2025-02-01', '2025-02-28'),
    (2, 2, 2, 'PHYSICAL',  'AUD', 'CONSTANT',   50.0, 82.00, '2025-02-01', '2025-02-28'),
    (3, 3, 3, 'FINANCIAL', 'NZD', 'VARIABLE',   75.0, 58.50, '2025-02-01', '2025-02-28'),
    (4, 1, 1, 'FINANCIAL', 'JPY', 'STANDARD',  200.0, 12.00, '2025-04-01', '2025-04-30'),
    (5, 2, 2, 'PHYSICAL',  'AUD', 'CONSTANT',   80.0, 85.00, '2025-04-01', '2025-04-30');
GO

-- ── Seed invoices (for Lab 13 — Settlement & Invoice Matching) ──
INSERT INTO invoice (trade_id, component_id, invoice_number, amount, currency, invoice_date, due_date, status, matched_amount, match_status)
VALUES
    (1, 1, 'INV-2025-02-001', 65000.00, 'JPY', '2025-03-01', '2025-03-31', 'PENDING', NULL, NULL),
    (2, 2, 'INV-2025-02-002', 41000.00, 'AUD', '2025-03-01', '2025-03-31', 'PENDING', NULL, NULL),
    (3, 3, 'INV-2025-02-003', 43875.00, 'NZD', '2025-03-01', '2025-03-31', 'MATCHED', 43875.00, 'EXACT'),
    (4, 4, 'INV-2025-04-001', 72000.00, 'JPY', '2025-05-01', '2025-05-31', 'PENDING', NULL, NULL),
    (5, 5, 'INV-2025-04-002', 68000.00, 'AUD', '2025-05-01', '2025-05-31', 'PENDING', NULL, NULL);

PRINT 'MSSQL init complete.';
GO

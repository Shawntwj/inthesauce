# SQL Query Cookbook — Trader & Business Requests

> **MDM Pivot Note:** Counterparty data is no longer stored in MSSQL. It has moved to the MDM Postgres database (`golden_record` table, port 5432). The `trade` table now references counterparties via `counterparty_mdm_id VARCHAR(50)` (e.g. `MDM-001`) instead of the old `counterparty_id INT`. Queries that need counterparty details (name, credit limit, etc.) should look up the `golden_record` table in MDM Postgres, or use the Redis cache populated by the `counterparty.updated` Kafka topic.

These are the queries you'd actually run on the job when someone asks for data.
MSSQL queries run against the `etrm` database. Counterparty queries run against MDM Postgres.

Run these in: **DBeaver** (MSSQL: localhost:1433, MDM Postgres: localhost:5432) or **Superset SQL Lab**.

---

## Trade Blotter Queries

### "Show me all open trades"
```sql
-- MSSQL: trade data (counterparty name must be looked up from MDM Postgres or Redis cache)
SELECT
    t.unique_id                         AS trade_ref,
    t.counterparty_mdm_id,
    tc.area_id,
    CASE tc.area_id
        WHEN 1 THEN 'JEPX'
        WHEN 2 THEN 'NEM'
        WHEN 3 THEN 'NZEM'
    END                                 AS market,
    tc.settlement_mode,
    tc.product_type,
    tc.quantity                         AS mw,
    tc.price,
    tc.price_denominator                AS currency,
    tc.quantity * tc.price              AS notional,
    tc.start_date,
    tc.end_date,
    DATEDIFF(day, tc.start_date, tc.end_date) AS delivery_days,
    t.trade_at_utc                      AS traded_at
FROM trade t
JOIN trade_component tc ON tc.trade_id = t.trade_id
WHERE t.is_active = 1
ORDER BY t.trade_at_utc DESC;

-- MDM Postgres: look up counterparty names by mdm_id
-- SELECT mdm_id, canonical_name, short_code FROM golden_record WHERE is_active = true;
```

### "Show me all trades for counterparty X"
```sql
-- Filter by MDM ID (e.g. MDM-001 = Tokyo Energy Corp, MDM-002 = AUS Grid Partners, MDM-003 = NZ Renewable Trust)
SELECT
    t.unique_id, t.counterparty_mdm_id, tc.area_id, tc.settlement_mode,
    tc.quantity, tc.price, tc.price_denominator,
    tc.start_date, tc.end_date
FROM trade t
JOIN trade_component tc ON tc.trade_id = t.trade_id
WHERE t.counterparty_mdm_id = 'MDM-001'   -- change to counterparty MDM ID
  AND t.is_active = 1
ORDER BY t.trade_at_utc DESC;
```

### "Show me all trades in JEPX this month"
```sql
SELECT
    t.unique_id, t.counterparty_mdm_id,
    tc.settlement_mode, tc.quantity, tc.price,
    tc.start_date, tc.end_date
FROM trade t
JOIN trade_component tc ON tc.trade_id = t.trade_id
WHERE tc.area_id = 1                              -- 1=JEPX, 2=NEM, 3=NZEM
  AND tc.start_date >= DATEADD(month, DATEDIFF(month, 0, GETDATE()), 0)  -- first day of this month
  AND t.is_active = 1;
```

---

## Exposure & Risk Queries

### "What is our total open exposure per counterparty?"

This now requires two steps: get exposure from MSSQL, then enrich with counterparty details from MDM Postgres.

```sql
-- Step 1 (MSSQL): Get exposure grouped by counterparty MDM ID
SELECT
    t.counterparty_mdm_id,
    COUNT(DISTINCT t.trade_id)      AS open_trades,
    SUM(tc.quantity * tc.price * DATEDIFF(day, tc.start_date, tc.end_date))
                                    AS total_notional
FROM trade t
LEFT JOIN trade_component tc ON tc.trade_id = t.trade_id
WHERE t.is_active = 1
GROUP BY t.counterparty_mdm_id
ORDER BY total_notional DESC;

-- Step 2 (MDM Postgres): Get counterparty details and credit limits
SELECT
    mdm_id,
    canonical_name,
    short_code,
    credit_limit,
    currency
FROM golden_record
WHERE is_active = true;
```

Compare the `total_notional` from step 1 against `credit_limit` from step 2 for each MDM ID to find remaining headroom.

### "Is counterparty X close to their credit limit?"
```sql
-- Step 1 (MSSQL): Get current exposure for a specific counterparty MDM ID
DECLARE @mdm_id VARCHAR(50) = 'MDM-001';  -- Tokyo Energy Corp

SELECT
    t.counterparty_mdm_id,
    SUM(tc.quantity * tc.price * DATEDIFF(day, tc.start_date, tc.end_date)) AS current_exposure
FROM trade t
JOIN trade_component tc ON tc.trade_id = t.trade_id
WHERE t.counterparty_mdm_id = @mdm_id AND t.is_active = 1
GROUP BY t.counterparty_mdm_id;

-- Step 2 (MDM Postgres): Get credit limit for that counterparty
-- SELECT mdm_id, canonical_name, credit_limit FROM golden_record WHERE mdm_id = 'MDM-001';
-- Compare current_exposure vs credit_limit to get headroom and utilisation_pct.
```

### "Show me volume by market area"
```sql
SELECT
    CASE tc.area_id WHEN 1 THEN 'JEPX' WHEN 2 THEN 'NEM' WHEN 3 THEN 'NZEM' END AS market,
    tc.settlement_mode,
    tc.price_denominator                                AS currency,
    COUNT(DISTINCT t.trade_id)                          AS trade_count,
    SUM(tc.quantity)                                    AS total_mw,
    AVG(tc.price)                                       AS avg_price,
    SUM(tc.quantity * tc.price)                         AS total_notional
FROM trade t
JOIN trade_component tc ON tc.trade_id = t.trade_id
WHERE t.is_active = 1
GROUP BY tc.area_id, tc.settlement_mode, tc.price_denominator
ORDER BY tc.area_id, tc.settlement_mode;
```

---

## Invoice Queries

### "Show me all pending invoices"
```sql
-- Counterparty name must be looked up from MDM Postgres by counterparty_mdm_id
SELECT
    i.invoice_number,
    t.unique_id             AS trade_ref,
    t.counterparty_mdm_id,
    i.amount,
    i.currency,
    i.invoice_date,
    i.due_date,
    DATEDIFF(day, GETDATE(), i.due_date) AS days_until_due,
    i.status,
    i.match_status
FROM invoice i
JOIN trade t        ON t.trade_id = i.trade_id
WHERE i.status = 'PENDING'
ORDER BY i.due_date ASC;
```

### "Show invoices with mismatches (need manual review)"
```sql
SELECT
    i.invoice_number,
    t.unique_id             AS trade_ref,
    t.counterparty_mdm_id,
    i.amount                AS our_amount,
    i.matched_amount        AS their_amount,
    i.amount - i.matched_amount AS difference,
    i.currency,
    i.invoice_date,
    i.match_status
FROM invoice i
JOIN trade t         ON t.trade_id = i.trade_id
WHERE i.match_status IN ('MISMATCH', 'PARTIAL')
ORDER BY ABS(i.amount - i.matched_amount) DESC;
```

### "Total invoiced vs matched per counterparty this month"
```sql
SELECT
    t.counterparty_mdm_id,
    i.currency,
    COUNT(i.invoice_id)             AS invoice_count,
    SUM(i.amount)                   AS total_invoiced,
    SUM(i.matched_amount)           AS total_matched,
    SUM(i.amount - ISNULL(i.matched_amount, 0)) AS unmatched_amount,
    SUM(CASE WHEN i.match_status = 'FULL'     THEN 1 ELSE 0 END) AS full_matches,
    SUM(CASE WHEN i.match_status = 'PARTIAL'  THEN 1 ELSE 0 END) AS partial_matches,
    SUM(CASE WHEN i.match_status = 'MISMATCH' THEN 1 ELSE 0 END) AS mismatches
FROM invoice i
JOIN trade t         ON t.trade_id = i.trade_id
WHERE i.invoice_date >= DATEADD(month, DATEDIFF(month, 0, GETDATE()), 0)
GROUP BY t.counterparty_mdm_id, i.currency
ORDER BY t.counterparty_mdm_id;
-- Look up counterparty names from MDM Postgres: SELECT mdm_id, canonical_name FROM golden_record;
```

---

## Settlement & Delivery Queries

### "Which trades deliver this week?"
```sql
SELECT
    t.unique_id, t.counterparty_mdm_id,
    tc.area_id,
    CASE tc.area_id WHEN 1 THEN 'JEPX' WHEN 2 THEN 'NEM' WHEN 3 THEN 'NZEM' END AS market,
    tc.settlement_mode,
    tc.quantity, tc.price, tc.price_denominator,
    tc.start_date, tc.end_date
FROM trade t
JOIN trade_component tc ON tc.trade_id = t.trade_id
WHERE tc.start_date <= DATEADD(day, 7, GETDATE())
  AND tc.end_date   >= GETDATE()
  AND t.is_active = 1
ORDER BY tc.start_date, tc.area_id;
```

### "Show me physical trades that need balance checking"
```sql
-- Physical trades where BUY and SELL should net to zero
SELECT
    CASE tc.area_id WHEN 1 THEN 'JEPX' WHEN 2 THEN 'NEM' WHEN 3 THEN 'NZEM' END AS market,
    tc.start_date,
    SUM(CASE WHEN tc.quantity > 0 THEN tc.quantity ELSE 0 END) AS buy_mw,
    SUM(CASE WHEN tc.quantity < 0 THEN ABS(tc.quantity) ELSE 0 END) AS sell_mw,
    SUM(tc.quantity) AS net_mw    -- should be 0 for balanced book
FROM trade t
JOIN trade_component tc ON tc.trade_id = t.trade_id
WHERE tc.settlement_mode = 'PHYSICAL'
  AND t.is_active = 1
GROUP BY tc.area_id, tc.start_date
HAVING SUM(tc.quantity) <> 0      -- flag imbalances
ORDER BY tc.area_id, tc.start_date;
```

---

## Useful MSSQL + ClickHouse Combined Queries

Run these in Superset SQL Lab — switch between ETRM MSSQL and ETRM ClickHouse as needed.

### Step 1 (MSSQL): Get trade details
```sql
-- Run in ETRM MSSQL
SELECT trade_id, unique_id, counterparty_mdm_id FROM trade WHERE is_active = 1;
```

### Step 2 (ClickHouse): Get P&L for those trades
```sql
-- Run in ETRM ClickHouse
SELECT
    trade_id,
    unique_id                               AS trade_ref,
    market_area,
    total_realized_pnl,
    total_unrealized_pnl,
    total_pnl,
    settled_intervals,
    pending_intervals,
    delivery_start,
    delivery_end
FROM etrm.vw_pnl_by_trade
ORDER BY total_pnl DESC;
```

### Daily P&L report (ClickHouse)
```sql
-- Run in ETRM ClickHouse
SELECT
    delivery_date,
    market_area,
    currency,
    daily_realized_pnl,
    daily_unrealized_pnl,
    daily_total_pnl,
    total_mw_delivered,
    active_trade_count
FROM etrm.vw_pnl_daily
ORDER BY delivery_date DESC, market_area;
```

---

## Trader-Style Quick Checks (30-second queries)

These are the things you run when a trader pings you on Teams:

```sql
-- "How many trades do we have?"
SELECT COUNT(*) FROM trade WHERE is_active = 1;

-- "What's our biggest trade by notional?"
SELECT TOP 1 t.unique_id, t.counterparty_mdm_id, tc.quantity * tc.price AS notional, tc.price_denominator
FROM trade t
JOIN trade_component tc ON tc.trade_id = t.trade_id
ORDER BY notional DESC;

-- "Is trade TRD-2025-001 still active?"
SELECT trade_id, unique_id, is_active, trade_at_utc
FROM trade WHERE unique_id = 'TRD-2025-001';

-- "What area does trade X trade in?"
SELECT t.unique_id, tc.area_id, tc.settlement_mode, tc.quantity, tc.price
FROM trade t
JOIN trade_component tc ON tc.trade_id = t.trade_id
WHERE t.unique_id = 'TRD-2025-001';

-- "Any invoices overdue?"
SELECT i.invoice_number, t.unique_id, t.counterparty_mdm_id, i.amount, i.due_date
FROM invoice i
JOIN trade t ON t.trade_id = i.trade_id
WHERE i.due_date < GETDATE() AND i.status = 'PENDING'
ORDER BY i.due_date ASC;
```

---

## MDM Postgres Queries (port 5432)

These queries run against the MDM Postgres database (`localhost:5432`, user `mdm`, password `mdmpass`, database `mdm`). Use DBeaver or Grafana Explore (MDM Postgres datasource).

### "Show me all counterparties"
```sql
SELECT
    mdm_id,
    canonical_name,
    short_code,
    credit_limit,
    collateral_amount,
    currency,
    is_active,
    data_steward,
    updated_at
FROM golden_record
WHERE is_active = true
ORDER BY mdm_id;
```

### "What is MDM-001's credit limit?"
```sql
SELECT mdm_id, canonical_name, credit_limit, currency
FROM golden_record
WHERE mdm_id = 'MDM-001';
```

### "Any incoming records from a specific source system?"
```sql
SELECT
    record_id,
    source_system,
    source_id,
    raw_name,
    credit_limit,
    match_status,
    matched_mdm_id,
    match_score,
    received_at
FROM incoming_record
WHERE source_system = 'BROKER_FEED'  -- or 'TRADING_DESK', 'INVOICE_SYSTEM'
ORDER BY received_at DESC;
```

### "Show me all open stewardship conflicts"
```sql
SELECT
    sq.queue_id,
    sq.conflict_fields,
    sq.status,
    sq.created_at,
    ir.source_system,
    ir.raw_name,
    ir.credit_limit AS incoming_credit_limit,
    gr.canonical_name,
    gr.credit_limit AS golden_credit_limit
FROM stewardship_queue sq
JOIN incoming_record ir ON ir.record_id = sq.record_a_id
LEFT JOIN golden_record gr ON gr.mdm_id = ir.matched_mdm_id
WHERE sq.status = 'OPEN'
ORDER BY sq.created_at DESC;
```

### "Match distribution — how many records auto-merged vs queued vs new?"
```sql
SELECT
    match_status,
    COUNT(*) AS record_count,
    ROUND(AVG(match_score), 1) AS avg_score
FROM incoming_record
GROUP BY match_status
ORDER BY record_count DESC;
```

### "Stewardship resolution stats"
```sql
SELECT
    status,
    COUNT(*) AS count,
    ROUND(AVG(EXTRACT(EPOCH FROM (resolved_at - created_at)) / 3600), 1) AS avg_hours_to_resolve
FROM stewardship_queue
GROUP BY status;
```

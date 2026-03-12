# SQL Query Cookbook — Trader & Business Requests

These are the queries you'd actually run on the job when someone asks for data.
All run against MSSQL (`etrm` database) unless marked ClickHouse.

Run these in: **DBeaver** (connect to localhost:1433) or **Superset SQL Lab** (select ETRM MSSQL).

---

## Trade Blotter Queries

### "Show me all open trades"
```sql
SELECT
    t.unique_id                         AS trade_ref,
    cp.name                             AS counterparty,
    cp.short_code,
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
JOIN counterparty cp    ON cp.counterparty_id = t.counterparty_id
WHERE t.is_active = 1
ORDER BY t.trade_at_utc DESC;
```

### "Show me all trades for counterparty X"
```sql
SELECT
    t.unique_id, tc.area_id, tc.settlement_mode,
    tc.quantity, tc.price, tc.price_denominator,
    tc.start_date, tc.end_date
FROM trade t
JOIN trade_component tc ON tc.trade_id = t.trade_id
JOIN counterparty cp    ON cp.counterparty_id = t.counterparty_id
WHERE cp.name = 'JERA Co., Ltd.'   -- change to counterparty name
  AND t.is_active = 1
ORDER BY t.trade_at_utc DESC;
```

### "Show me all trades in JEPX this month"
```sql
SELECT
    t.unique_id, cp.name AS counterparty,
    tc.settlement_mode, tc.quantity, tc.price,
    tc.start_date, tc.end_date
FROM trade t
JOIN trade_component tc ON tc.trade_id = t.trade_id
JOIN counterparty cp    ON cp.counterparty_id = t.counterparty_id
WHERE tc.area_id = 1                              -- 1=JEPX, 2=NEM, 3=NZEM
  AND tc.start_date >= DATEADD(month, DATEDIFF(month, 0, GETDATE()), 0)  -- first day of this month
  AND t.is_active = 1;
```

---

## Exposure & Risk Queries

### "What is our total open exposure per counterparty?"
```sql
SELECT
    cp.name                         AS counterparty,
    cp.short_code,
    cp.credit_limit,
    COUNT(DISTINCT t.trade_id)      AS open_trades,
    SUM(tc.quantity * tc.price * DATEDIFF(day, tc.start_date, tc.end_date))
                                    AS total_notional,
    cp.credit_limit -
    SUM(tc.quantity * tc.price * DATEDIFF(day, tc.start_date, tc.end_date))
                                    AS remaining_headroom
FROM counterparty cp
LEFT JOIN trade t          ON t.counterparty_id = cp.counterparty_id AND t.is_active = 1
LEFT JOIN trade_component tc ON tc.trade_id = t.trade_id
GROUP BY cp.counterparty_id, cp.name, cp.short_code, cp.credit_limit
ORDER BY total_notional DESC;
```

### "Is counterparty X close to their credit limit?"
```sql
DECLARE @cpty_name VARCHAR(200) = 'JERA Co., Ltd.';

SELECT
    cp.name,
    cp.credit_limit,
    SUM(tc.quantity * tc.price * DATEDIFF(day, tc.start_date, tc.end_date)) AS current_exposure,
    cp.credit_limit - SUM(tc.quantity * tc.price * DATEDIFF(day, tc.start_date, tc.end_date)) AS headroom,
    CAST(
        SUM(tc.quantity * tc.price * DATEDIFF(day, tc.start_date, tc.end_date))
        / cp.credit_limit * 100
    AS DECIMAL(5,1))                AS utilisation_pct
FROM counterparty cp
JOIN trade t           ON t.counterparty_id = cp.counterparty_id AND t.is_active = 1
JOIN trade_component tc ON tc.trade_id = t.trade_id
WHERE cp.name = @cpty_name
GROUP BY cp.name, cp.credit_limit;
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
SELECT
    i.invoice_number,
    t.unique_id             AS trade_ref,
    cp.name                 AS counterparty,
    i.amount,
    i.currency,
    i.invoice_date,
    i.due_date,
    DATEDIFF(day, GETDATE(), i.due_date) AS days_until_due,
    i.status,
    i.match_status
FROM invoice i
JOIN trade t        ON t.trade_id = i.trade_id
JOIN counterparty cp ON cp.counterparty_id = t.counterparty_id
WHERE i.status = 'PENDING'
ORDER BY i.due_date ASC;
```

### "Show invoices with mismatches (need manual review)"
```sql
SELECT
    i.invoice_number,
    t.unique_id             AS trade_ref,
    cp.name                 AS counterparty,
    i.amount                AS our_amount,
    i.matched_amount        AS their_amount,
    i.amount - i.matched_amount AS difference,
    i.currency,
    i.invoice_date,
    i.match_status
FROM invoice i
JOIN trade t         ON t.trade_id = i.trade_id
JOIN counterparty cp ON cp.counterparty_id = t.counterparty_id
WHERE i.match_status IN ('MISMATCH', 'PARTIAL')
ORDER BY ABS(i.amount - i.matched_amount) DESC;
```

### "Total invoiced vs matched per counterparty this month"
```sql
SELECT
    cp.name                         AS counterparty,
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
JOIN counterparty cp ON cp.counterparty_id = t.counterparty_id
WHERE i.invoice_date >= DATEADD(month, DATEDIFF(month, 0, GETDATE()), 0)
GROUP BY cp.name, i.currency
ORDER BY cp.name;
```

---

## Settlement & Delivery Queries

### "Which trades deliver this week?"
```sql
SELECT
    t.unique_id, cp.name AS counterparty,
    tc.area_id,
    CASE tc.area_id WHEN 1 THEN 'JEPX' WHEN 2 THEN 'NEM' WHEN 3 THEN 'NZEM' END AS market,
    tc.settlement_mode,
    tc.quantity, tc.price, tc.price_denominator,
    tc.start_date, tc.end_date
FROM trade t
JOIN trade_component tc ON tc.trade_id = t.trade_id
JOIN counterparty cp    ON cp.counterparty_id = t.counterparty_id
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
SELECT trade_id, unique_id, counterparty_id FROM trade WHERE is_active = 1;
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
SELECT TOP 1 t.unique_id, cp.name, tc.quantity * tc.price AS notional, tc.price_denominator
FROM trade t
JOIN trade_component tc ON tc.trade_id = t.trade_id
JOIN counterparty cp ON cp.counterparty_id = t.counterparty_id
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
SELECT i.invoice_number, t.unique_id, cp.name, i.amount, i.due_date
FROM invoice i
JOIN trade t ON t.trade_id = i.trade_id
JOIN counterparty cp ON cp.counterparty_id = t.counterparty_id
WHERE i.due_date < GETDATE() AND i.status = 'PENDING'
ORDER BY i.due_date ASC;
```

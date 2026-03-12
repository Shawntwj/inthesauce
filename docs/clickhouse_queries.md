# ClickHouse Query Cookbook

Reference for every pattern you'll use on the job.
All queries run against the `etrm` database in this sandbox.

---

## Why ClickHouse Behaves Differently From MSSQL

| Concept | MSSQL | ClickHouse |
|---|---|---|
| Update a row | `UPDATE table SET ...` | Not supported — insert a new row instead |
| Delete a row | `DELETE FROM table WHERE ...` | Not supported in real-time — use mutations (async) |
| Get latest value | Just query — data is current | Must use `argMax` or `FINAL` to deduplicate |
| Primary key | Enforces uniqueness, fast lookup | Orders data on disk for compression — NOT a uniqueness constraint |
| Transactions | Full ACID | None — writes are eventual |
| Best for | Trades, invoices, counterparties (row-by-row operations) | Market data, P&L timeseries, millions of interval rows |

The core rule: **ClickHouse is a log.** You append to it, never edit it. Every version of a row exists forever. You query the latest version using `FINAL` or `argMax`.

---

## Pattern 1: Deduplication with FINAL

`ReplacingMergeTree` tables keep all versions of a row on disk. Merges happen in the background. Until a merge happens, duplicates exist.

`FINAL` forces deduplication at query time — always use it when you want the latest state.

```sql
-- WITHOUT FINAL: may return duplicate rows (multiple versions of same interval)
SELECT trade_id, interval_start, realized_pnl
FROM etrm.transaction_exploded
WHERE trade_id = 1;

-- WITH FINAL: returns only the latest version of each row
SELECT trade_id, interval_start, realized_pnl
FROM etrm.transaction_exploded FINAL
WHERE trade_id = 1;
```

**When to use FINAL:** Any time you want "current state" — P&L, market prices, positions.
**When NOT to use FINAL:** When you deliberately want history (e.g. audit trail of all versions).

**Performance note:** `FINAL` is slower on large tables. For production, use `argMax` instead (Pattern 2).

---

## Pattern 2: Latest Value with argMax

`argMax(value_col, version_col)` returns the value from the row with the highest version. This is faster than `FINAL` on large datasets because it aggregates instead of deduplicating.

```sql
-- Latest market price per area
SELECT
    area_id,
    argMax(price, issue_datetime)  AS latest_price,
    argMax(volume, issue_datetime) AS latest_volume,
    argMax(currency, issue_datetime) AS currency,
    max(issue_datetime)            AS as_of
FROM etrm.market_data
GROUP BY area_id;

-- Latest MTM curve price per date per curve
SELECT
    curve_id,
    value_datetime,
    argMax(price, issue_datetime) AS mtm_price
FROM etrm.mtm_curve
GROUP BY curve_id, value_datetime
ORDER BY curve_id, value_datetime;
```

**Rule:** If you see `GROUP BY` with `argMax`, you're getting the latest value per group. Always pair it with the `issue_datetime` column as the version.

---

## Pattern 3: MTM Fallback (COALESCE)

The core P&L valuation pattern. Use the settlement price if the interval has been settled (past delivery), otherwise fall back to the MTM curve price (future delivery estimate).

```sql
-- Valuation price per interval: settle if available, else MTM
SELECT
    trade_id,
    interval_start,
    quantity,
    price                                           AS contracted_price,
    settle_price,
    mtm_price,
    COALESCE(settle_price, mtm_price)               AS valuation_price,
    quantity * (COALESCE(settle_price, mtm_price) - price) AS interval_pnl
FROM etrm.transaction_exploded FINAL
WHERE trade_id = 1
ORDER BY interval_start;

-- Aggregate P&L per trade
SELECT
    trade_id,
    unique_id                                       AS trade_ref,
    SUM(COALESCE(realized_pnl, 0))                  AS total_realized,
    SUM(COALESCE(unrealized_pnl, 0))                AS total_unrealized,
    SUM(COALESCE(realized_pnl, 0))
      + SUM(COALESCE(unrealized_pnl, 0))            AS total_pnl,
    countIf(settle_price IS NOT NULL)               AS settled_intervals,
    countIf(settle_price IS NULL)                   AS open_intervals
FROM etrm.transaction_exploded FINAL
GROUP BY trade_id, unique_id
ORDER BY total_pnl DESC;
```

---

## Pattern 4: Time Travel

Every row has `issue_datetime` — when the data was published. You can reconstruct what the system "knew" at any point in time by filtering on `issue_datetime`.

```sql
-- What did market prices look like as of Jan 15?
SELECT
    area_id,
    value_datetime,
    argMax(price, issue_datetime) AS price_as_of_jan15
FROM etrm.market_data
WHERE issue_datetime <= '2025-01-15 00:00:00'
GROUP BY area_id, value_datetime
ORDER BY area_id, value_datetime;

-- What was the P&L on trade 1 as of a specific snapshot?
SELECT
    trade_id,
    interval_start,
    realized_pnl,
    unrealized_pnl,
    issue_datetime AS snapshot_time
FROM etrm.transaction_exploded
WHERE trade_id = 1
  AND issue_datetime <= '2025-01-20 00:00:00'
ORDER BY interval_start, issue_datetime DESC
LIMIT 1 BY interval_start;  -- ClickHouse: take latest row per interval_start
```

**When this matters on the job:** Trader disputes a P&L figure from last week. You need to show what the system calculated at that exact point in time, not today's recalculated value.

---

## Pattern 5: Daily / Hourly Aggregation

ClickHouse has powerful date functions. Common ones you'll use:

```sql
-- P&L by day
SELECT
    toDate(interval_start)          AS delivery_date,
    area_id,
    SUM(COALESCE(realized_pnl, 0))  AS daily_realized,
    SUM(COALESCE(unrealized_pnl, 0)) AS daily_unrealized,
    SUM(quantity)                   AS total_mw
FROM etrm.transaction_exploded FINAL
GROUP BY toDate(interval_start), area_id
ORDER BY delivery_date, area_id;

-- P&L by month
SELECT
    toStartOfMonth(interval_start)  AS month,
    currency,
    SUM(COALESCE(realized_pnl, 0))  AS monthly_realized_pnl
FROM etrm.transaction_exploded FINAL
GROUP BY toStartOfMonth(interval_start), currency
ORDER BY month;

-- Market price by hour (peak hour analysis)
SELECT
    toHour(value_datetime)          AS hour_of_day,
    area_id,
    AVG(latest_price)               AS avg_hourly_price
FROM etrm.vw_market_prices_latest
GROUP BY toHour(value_datetime), area_id
ORDER BY area_id, hour_of_day;
```

**Useful ClickHouse date functions:**

| Function | Output | Example |
|---|---|---|
| `toDate(dt)` | `2025-01-15` | Strip time part |
| `toStartOfMonth(dt)` | `2025-01-01` | First day of month |
| `toStartOfWeek(dt)` | `2025-01-13` | Monday of week |
| `toHour(dt)` | `14` | Hour 0-23 |
| `formatDateTime(dt, '%Y-%m')` | `2025-01` | Custom format |
| `dateDiff('day', start, end)` | `30` | Days between two dates |

---

## Pattern 6: Comparing Contracted Price vs Market Price

Common trader request: "show me all trades where we're currently losing money."

```sql
-- Trades where current MTM price is below contracted price (losing money as seller)
SELECT
    t.trade_id,
    t.unique_id AS trade_ref,
    t.area_id,
    AVG(t.price)     AS avg_contracted_price,
    AVG(t.mtm_price) AS avg_current_mtm,
    AVG(t.mtm_price) - AVG(t.price) AS price_diff_per_mw,
    SUM(t.quantity)  AS total_open_mw,
    SUM(t.quantity * (t.mtm_price - t.price)) AS total_unrealized_pnl
FROM etrm.transaction_exploded FINAL t
WHERE t.settle_price IS NULL          -- only open/future intervals
  AND t.mtm_price IS NOT NULL
GROUP BY t.trade_id, t.unique_id, t.area_id
HAVING total_unrealized_pnl < 0       -- only losing trades
ORDER BY total_unrealized_pnl ASC;    -- worst first
```

---

## Pattern 7: Position / Exposure by Area

Common risk manager request: "what is our net position in JEPX right now?"

```sql
-- Net open MW position per market area
SELECT
    area_id,
    CASE area_id WHEN 1 THEN 'JEPX' WHEN 2 THEN 'NEM' WHEN 3 THEN 'NZEM' END AS market,
    SUM(quantity)                       AS total_open_mw,
    COUNT(DISTINCT trade_id)            AS open_trades,
    SUM(quantity * price)               AS total_contracted_notional,
    currency
FROM etrm.transaction_exploded FINAL
WHERE settle_price IS NULL              -- only future/open intervals
  AND interval_start > now()
GROUP BY area_id, currency
ORDER BY area_id;
```

---

## Pattern 8: Market Price Curve Shape

For visualising the forward curve — what prices are implied for future delivery.

```sql
-- Forward curve for all areas: next 30 days
SELECT
    value_date,
    market_area,
    mtm_price,
    source
FROM etrm.vw_mtm_curve_latest
WHERE value_date BETWEEN today() AND today() + INTERVAL 30 DAY
ORDER BY market_area, value_date;

-- Compare market price to MTM curve (basis)
SELECT
    m.value_date,
    m.market_area,
    m.latest_price          AS spot_price,
    c.mtm_price             AS curve_price,
    m.latest_price - c.mtm_price AS basis
FROM etrm.vw_market_prices_latest m
JOIN etrm.vw_mtm_curve_latest c
  ON m.value_date = c.value_date AND m.area_id = c.curve_id
ORDER BY m.market_area, m.value_date;
```

---

## Pattern 9: Debugging Duplicate Data

If you suspect duplicates or want to understand how ReplacingMergeTree works:

```sql
-- Count versions per interval (>1 means duplicates not yet merged)
SELECT
    trade_id,
    interval_start,
    COUNT(*) AS version_count,
    groupArray(issue_datetime) AS all_versions
FROM etrm.transaction_exploded
GROUP BY trade_id, interval_start
HAVING version_count > 1
ORDER BY version_count DESC
LIMIT 20;

-- System tables: check merge status
SELECT
    table,
    rows,
    bytes_on_disk,
    modification_time
FROM system.parts
WHERE database = 'etrm'
  AND active = 1
ORDER BY table, modification_time DESC;
```

---

## Views Available in This Sandbox

These are pre-built flat views — use them in Superset or DBeaver without needing to write JOINs.

| View | What It Returns | Best For |
|---|---|---|
| `etrm.vw_pnl_by_trade` | One row per trade: total realized + unrealized P&L | P&L report, trade book overview |
| `etrm.vw_pnl_daily` | One row per day per area: daily P&L | Daily P&L chart |
| `etrm.vw_market_prices_latest` | Latest price per datetime per area | Price charts, spot market view |
| `etrm.vw_mtm_curve_latest` | Latest MTM price per curve per datetime | Forward curve charts |
| `etrm.vw_trade_intervals_flat` | Every interval with all fields flat | Drill-down analysis, debugging |

```sql
-- Quick check: P&L summary across all trades
SELECT * FROM etrm.vw_pnl_by_trade ORDER BY total_pnl DESC;

-- Quick check: today's prices
SELECT * FROM etrm.vw_market_prices_latest WHERE value_date = today();
```

---

## Common Mistakes

| Mistake | What Goes Wrong | Fix |
|---|---|---|
| Forgetting `FINAL` | Get duplicate rows, wrong aggregates | Add `FINAL` after table name |
| Using `COUNT(*)` without `FINAL` | Inflated counts | `COUNT(*)` + `FINAL`, or use a view |
| `WHERE date_col = '2025-01-15'` on DateTime | Returns nothing | Use `toDate(date_col) = '2025-01-15'` or `>= / <` range |
| `SELECT *` on large table | Slow, scans all columns | Name only the columns you need |
| `COALESCE` on non-Nullable column | Unnecessary but harmless | Only needed on `Nullable(Float64)` columns |
| Using `LIMIT` before `GROUP BY` | Syntax error | `LIMIT` always goes at the end |

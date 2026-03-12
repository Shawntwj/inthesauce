# Lab 1 — Databases: MSSQL + ClickHouse

**Prereqs:** Docker stack running (`make up`). DBeaver installed.
**Time:** 45-60 minutes
**Goal:** Be comfortable querying both databases, understand the difference in how they behave.

---

## Setup (MUST DO FIRST)

Azure SQL Edge does NOT auto-run init scripts on startup. You need to run them manually.

### Step 1: Initialise MSSQL
Open DBeaver, connect to MSSQL (`localhost:1433`, user `sa`, password `YourStr0ngPass1`). Open the file `scripts/init_mssql.sql` and execute the entire script. This creates the `etrm` database, all tables, and seed data.

### Step 2: Initialise ClickHouse
```bash
make clickhouse-init
```

### Step 3: Create reporting views
```bash
make powerbi-views
```
Then in DBeaver (connected to MSSQL, database `etrm`), open and execute `scripts/powerbi_views_mssql.sql`.

### Step 4: Verify everything
```bash
make check-health
```

---

## Part A — MSSQL (15 min)

Connect in DBeaver: `localhost:1433`, user `sa`, password `YourStr0ngPass1`, database `etrm`.

### Task A1: Explore the schema
1. Expand `etrm` → `Tables` in the DBeaver tree
2. Right-click `trade` → View Data — how many rows do you see?
3. Right-click `counterparty` → View Data — note the credit limits

**Expected:** 5 trades, 3 counterparties, 5 trade_components

### Task A2: Run the trade blotter query
Copy this into a DBeaver SQL editor and run it:
```sql
SELECT
    t.unique_id         AS trade_ref,
    cp.name             AS counterparty,
    tc.area_id,
    tc.settlement_mode,
    tc.quantity,
    tc.price,
    tc.price_denominator AS currency,
    tc.quantity * tc.price AS notional,
    tc.start_date,
    tc.end_date
FROM trade t
JOIN trade_component tc ON tc.trade_id = t.trade_id
JOIN counterparty cp    ON cp.counterparty_id = t.counterparty_id
WHERE t.is_active = 1
ORDER BY t.trade_at_utc DESC;
```

**Questions to answer:**
- Which counterparty has the most trades?
- What markets are represented? (area_id 1=JEPX, 2=NEM, 3=NZEM)
- Is any trade FINANCIAL vs PHYSICAL?

### Task A3: Add a new counterparty manually
```sql
INSERT INTO counterparty (name, short_code, credit_limit, collateral_amount, is_active)
VALUES ('Tokyo Gas Co., Ltd.', 'TGC', 4000000.00, 0, 1);
```

Verify it was inserted:
```sql
SELECT * FROM counterparty;
```

**Expected:** 4 rows now. Your new counterparty appears.

### Task A4: Check credit exposure
Run the exposure query from `docs/sql_query_cookbook.md`:
```sql
SELECT
    cp.name,
    cp.credit_limit,
    COUNT(DISTINCT t.trade_id) AS open_trades,
    SUM(tc.quantity * tc.price * DATEDIFF(day, tc.start_date, tc.end_date)) AS total_notional
FROM counterparty cp
LEFT JOIN trade t           ON t.counterparty_id = cp.counterparty_id AND t.is_active = 1
LEFT JOIN trade_component tc ON tc.trade_id = t.trade_id
GROUP BY cp.counterparty_id, cp.name, cp.credit_limit
ORDER BY total_notional DESC;
```

**Question:** Is any counterparty over their credit limit? What would happen if a new trade came in for the most-exposed one?

---

## Part B — ClickHouse (15 min)

Connect in DBeaver: `localhost:8123` (HTTP), user `default`, no password, database `etrm`.

Or use Superset SQL Lab → select ETRM ClickHouse.

### Task B1: Understand FINAL

Run WITHOUT FINAL first:
```sql
SELECT trade_id, interval_start, realized_pnl, unrealized_pnl, issue_datetime
FROM etrm.transaction_exploded
LIMIT 20;
```

Now WITH FINAL:
```sql
SELECT trade_id, interval_start, realized_pnl, unrealized_pnl, issue_datetime
FROM etrm.transaction_exploded FINAL
LIMIT 20;
```

**Question:** Do you see any difference in row count for trade_id=1? The seed data deliberately inserted two versions of the first 10 days of TRADE-JP-001 (with different `issue_datetime` values). Without `FINAL`, you'll see both versions. With `FINAL`, you'll only see the latest.

Try this to see the difference clearly:
```sql
-- Count without FINAL (includes duplicates)
SELECT count(*) FROM etrm.transaction_exploded WHERE trade_id = 1;

-- Count with FINAL (deduplicated)
SELECT count(*) FROM etrm.transaction_exploded FINAL WHERE trade_id = 1;
```
The difference = the number of duplicate rows that haven't been merged yet.

### Task B2: Latest market price per area
```sql
SELECT
    area_id,
    CASE area_id WHEN 1 THEN 'JEPX' WHEN 2 THEN 'NEM' WHEN 3 THEN 'NZEM' END AS market,
    argMax(price, issue_datetime)  AS latest_price,
    argMax(currency, issue_datetime) AS currency,
    max(issue_datetime)            AS data_as_of
FROM etrm.market_data
GROUP BY area_id
ORDER BY area_id;
```

**Expected:** 3 rows, one per market area.

### Task B3: P&L across all trades
```sql
SELECT
    trade_id,
    unique_id,
    market_area,
    total_realized_pnl,
    total_unrealized_pnl,
    total_pnl,
    settled_intervals,
    pending_intervals
FROM etrm.vw_pnl_by_trade
ORDER BY total_pnl DESC;
```

**Questions:**
- Which trade has the best P&L?
- How many settled vs pending intervals are there?
- What does it mean when `settled_intervals = 0` for a trade?

### Task B4: Simulate inserting a new market price version
This demonstrates how ClickHouse handles updates:
```sql
-- Insert a new price version for JEPX (area_id=1) for a specific datetime
-- with a higher issue_datetime (simulating a price update)
INSERT INTO etrm.market_data
(value_date, value_datetime, issue_datetime, area_id, price, volume, source, currency)
VALUES
(today(), now(), now(), 1, 999.99, 100.0, 'LAB_TEST', 'JPY');
```

Now check that `argMax` returns your new price:
```sql
SELECT
    area_id,
    argMax(price, issue_datetime) AS latest_price,
    max(issue_datetime) AS as_of
FROM etrm.market_data
WHERE area_id = 1
GROUP BY area_id;
```

**Expected:** `latest_price = 999.99` — your inserted price is now "latest" because it has the highest `issue_datetime`.

**Cleanup** (insert a realistic price to restore):
```sql
INSERT INTO etrm.market_data
(value_date, value_datetime, issue_datetime, area_id, price, volume, source, currency)
VALUES
(today(), now(), now() + INTERVAL 1 SECOND, 1, 15.50, 100.0, 'JEPX', 'JPY');
```

---

## Part C — Superset SQL Lab (15 min)

Open `http://localhost:8088` → SQL Lab → SQL Editor

### Task C1: Run a cross-database workflow
1. Select **ETRM MSSQL** → run:
```sql
SELECT t.trade_id, t.unique_id, cp.name AS counterparty
FROM trade t JOIN counterparty cp ON cp.counterparty_id = t.counterparty_id;
```
Note the trade_ids.

2. Switch to **ETRM ClickHouse** → run:
```sql
SELECT trade_id, total_pnl, total_realized_pnl, total_unrealized_pnl
FROM etrm.vw_pnl_by_trade
ORDER BY trade_id;
```

3. **Manually join the results in your head** (or write them down): for each trade_id, what counterparty is it and what is the P&L?

This is what Power BI's data model relationship does automatically. Understanding it manually first helps you configure it correctly later.

### Task C2: Save a query as a chart
1. Run this in SQL Lab:
```sql
SELECT market_area, AVG(latest_price) AS avg_price
FROM etrm.vw_market_prices_latest
GROUP BY market_area;
```
2. Click **Explore** (top right of results) → chart type: **Bar Chart**
3. Save it as "Avg Market Price by Area"
4. Add it to the Market Data dashboard

---

## Checkpoint: What You Should Be Able to Do

- [ ] Connect DBeaver to both MSSQL and ClickHouse
- [ ] Explain why MSSQL uses `JOIN` and ClickHouse uses `argMax`
- [ ] Run a trade blotter query and read the results
- [ ] Explain what `FINAL` does and when to use it
- [ ] Insert a new row into ClickHouse and verify `argMax` returns it
- [ ] Run queries in Superset SQL Lab against both databases

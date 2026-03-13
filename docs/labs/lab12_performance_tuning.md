# Lab 12 — Performance Tuning: Making Queries 100x Faster

**Prereqs:** Labs 1, 4 complete. All containers running.
**Time:** 60-90 minutes
**Goal:** Learn to profile, diagnose, and fix slow queries across MSSQL and ClickHouse — the kind of work that makes senior engineers invaluable.

---

## Why This Matters

In production, the morning P&L report runs at 6:30 AM. If it takes 2 minutes, traders get their numbers by 6:32. If it takes 20 minutes because someone wrote a bad query, traders get nothing until 6:50 and you get a phone call. Performance isn't optional in trading systems.

---

## Part A — ClickHouse Query Profiling (25 min)

### Task A1: Measure a slow query

Run this intentionally slow query and measure it:

```sql
-- SLOW: Full table scan without FINAL, no filters
SELECT
    trade_id,
    count(*) AS intervals,
    sum(COALESCE(realized_pnl, 0) + COALESCE(unrealized_pnl, 0)) AS total_pnl
FROM etrm.transaction_exploded
GROUP BY trade_id
ORDER BY total_pnl DESC;
```

Note the query time from the ClickHouse response header.

Now add `FINAL`:

```sql
-- BETTER: With FINAL (deduplication)
SELECT
    trade_id,
    count(*) AS intervals,
    sum(COALESCE(realized_pnl, 0) + COALESCE(unrealized_pnl, 0)) AS total_pnl
FROM etrm.transaction_exploded FINAL
GROUP BY trade_id
ORDER BY total_pnl DESC;
```

**Question:** Is FINAL faster or slower? (It's usually slower because it forces deduplication at query time. But the results are correct.)

### Task A2: Use system.query_log to profile

```sql
-- Check the last 10 queries and their performance
SELECT
    query_id,
    query_duration_ms,
    read_rows,
    read_bytes,
    result_rows,
    memory_usage,
    query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query NOT LIKE '%system.query_log%'
ORDER BY event_time DESC
LIMIT 10;
```

**What to look for:**
- `read_rows` — how many rows did ClickHouse scan? If it's millions for a result of 5, you need better filtering
- `memory_usage` — did the query use more memory than expected?
- `query_duration_ms` — anything over 1000ms is a candidate for optimization

### Task A3: Compare argMax vs FINAL

These two approaches give the same result but perform very differently:

```sql
-- Approach 1: FINAL (dedup at query time)
SELECT count(*) FROM etrm.market_data FINAL WHERE area_id = 1;

-- Approach 2: Subquery with argMax (explicit dedup)
SELECT count(*) FROM (
    SELECT
        value_datetime,
        argMax(price, issue_datetime) AS price
    FROM etrm.market_data
    WHERE area_id = 1
    GROUP BY value_datetime
);
```

Run both and compare `query_duration_ms` from `system.query_log`. Which is faster? Why?

**Key insight:** For `ReplacingMergeTree`, `FINAL` performs a merge-sort of all parts at query time. `argMax` with `GROUP BY` can be faster because ClickHouse can use indices and skip data more aggressively.

### Task A4: Understand projections (ClickHouse pre-aggregation)

```sql
-- Create a projection that pre-aggregates P&L by trade
ALTER TABLE etrm.transaction_exploded
ADD PROJECTION pnl_by_trade (
    SELECT
        trade_id,
        sum(COALESCE(realized_pnl, 0)) AS total_realized,
        sum(COALESCE(unrealized_pnl, 0)) AS total_unrealized,
        count() AS interval_count
    GROUP BY trade_id
);

-- Materialize it (builds the projection from existing data)
ALTER TABLE etrm.transaction_exploded MATERIALIZE PROJECTION pnl_by_trade;
```

Now run the P&L query again and check if it uses the projection:
```sql
EXPLAIN SELECT trade_id, sum(COALESCE(realized_pnl, 0)) FROM etrm.transaction_exploded GROUP BY trade_id;
```

Look for `ReadFromMergeTree (Projection: pnl_by_trade)` in the output.

---

## Part B — MSSQL Query Optimization (25 min)

### Task B1: Check execution plans

Connect to MSSQL via DBeaver or Superset SQL Lab:

```sql
-- Enable execution plan display (DBeaver: Ctrl+Shift+E, or prefix with SET STATISTICS)
SET STATISTICS IO ON;
SET STATISTICS TIME ON;

-- Run a query that joins multiple tables
SELECT
    t.unique_id,
    t.counterparty_mdm_id,
    tc.area_id,
    tc.quantity * tc.price AS notional,
    tc.start_date,
    tc.end_date
FROM trade t
JOIN trade_component tc ON tc.trade_id = t.trade_id
WHERE t.is_active = 1
  AND tc.area_id = 1;
```

**Read the statistics output:**
- `Table scan` — bad, means no index is being used
- `Logical reads` — number of 8KB pages read from memory
- `Elapsed time` — total query time

### Task B2: Add an index and measure the improvement

```sql
-- Create an index on area_id (commonly filtered column)
CREATE NONCLUSTERED INDEX IX_trade_component_area
ON trade_component (area_id)
INCLUDE (trade_id, quantity, price, start_date, end_date);
```

Re-run the query from Task B1. Did `logical reads` decrease?

### Task B3: Understand the vw_trade_blotter view performance

```sql
-- This view joins 3 tables — check its plan
SELECT * FROM vw_trade_blotter WHERE market_area = 'JEPX';
```

The `CASE` expression for `market_area` runs AFTER the join, so MSSQL can't use an index on the CASE result. To filter efficiently:

```sql
-- BETTER: filter on the base column, not the computed one
SELECT * FROM vw_trade_blotter WHERE area_id = 1;
```

**This is a real-world lesson:** BI tools often generate SQL with filters on computed columns. Understanding this helps you design views that perform well.

### Task B4: Understand the half_hour_intervals calendar table

```sql
-- How many rows?
SELECT count(*) FROM half_hour_intervals;

-- This is a common pattern: pre-generated calendar/time dimension
-- Used for LEFT JOINs to ensure every slot appears even if no trade covers it
SELECT
    hhi.interval_start,
    hhi.trade_date,
    hhi.is_weekend,
    te.quantity,
    te.price
FROM half_hour_intervals hhi
LEFT JOIN (
    SELECT interval_start, quantity, price
    FROM etrm.transaction_exploded FINAL
    WHERE trade_id = 1
) te ON te.interval_start = hhi.interval_start  -- This would need to be in the same DB
WHERE hhi.trade_date BETWEEN '2025-02-01' AND '2025-02-28'
ORDER BY hhi.interval_start;
```

**Note:** This cross-database join won't work directly. In production, you'd either:
1. Replicate the calendar table to ClickHouse
2. Generate the calendar in ClickHouse using `arrayJoin(range(...))`
3. Use a Go service to merge the results

---

## Part C — Batch Insert Performance (20 min)

### Task C1: Row-by-row vs batch insert in ClickHouse

```sql
-- SLOW: One insert at a time (simulating row-by-row from an app)
INSERT INTO etrm.market_data VALUES
(today(), now(), now(), 1, 15.00, 100, 'PERF_TEST', 'JPY');
INSERT INTO etrm.market_data VALUES
(today(), now() + INTERVAL 30 MINUTE, now(), 1, 15.10, 100, 'PERF_TEST', 'JPY');
-- ... imagine 1000 of these
```

```sql
-- FAST: Single batch insert
INSERT INTO etrm.market_data
SELECT
    toDate(slot) AS value_date,
    slot AS value_datetime,
    now() AS issue_datetime,
    1 AS area_id,
    15.0 + (rand() % 100) / 100.0 AS price,
    100.0 AS volume,
    'PERF_BATCH' AS source,
    'JPY' AS currency
FROM (
    SELECT toDateTime('2025-06-01 00:00:00') + INTERVAL (number * 30) MINUTE AS slot
    FROM numbers(10000)
);
```

Check `system.query_log` — the batch insert should be 100-1000x faster.

### Task C2: Understand why batching matters

```sql
-- How many "parts" does the table have?
SELECT
    table,
    count() AS parts,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS disk_size
FROM system.parts
WHERE database = 'etrm' AND active
GROUP BY table
ORDER BY total_rows DESC;
```

**Key insight:** Each INSERT creates a new "part" in ClickHouse. Too many parts = slow queries because ClickHouse must merge-sort them. Batch inserts create fewer, larger parts.

If `parts` count is very high (>100 for a small table):
```sql
-- Force a merge
OPTIMIZE TABLE etrm.market_data FINAL;

-- Check again
SELECT table, count() AS parts FROM system.parts
WHERE database = 'etrm' AND table = 'market_data' AND active
GROUP BY table;
```

### Task C3: Clean up performance test data

```sql
-- Insert a "cleanup" version with newer issue_datetime
-- (This doesn't actually delete, but FINAL/argMax will prefer these)
-- In practice, you'd just leave old data — ClickHouse handles it via TTL or partitions
```

---

## Part D — Real-World Performance Patterns (15 min)

### Task D1: Partition pruning

ClickHouse tables are partitioned by month (`PARTITION BY toYYYYMM(...)`). Queries that filter by date only scan relevant partitions:

```sql
-- FAST: Only scans February 2025 partition
SELECT count(*) FROM etrm.transaction_exploded FINAL
WHERE interval_start >= '2025-02-01' AND interval_start < '2025-03-01';

-- SLOW: Scans all partitions
SELECT count(*) FROM etrm.transaction_exploded FINAL;
```

Check with:
```sql
EXPLAIN SELECT count(*) FROM etrm.transaction_exploded FINAL
WHERE interval_start >= '2025-02-01' AND interval_start < '2025-03-01';
```

Look for `Parts: X/Y` — X is how many parts were read, Y is total. If X << Y, partition pruning is working.

### Task D2: Sampling for large datasets

When you have millions of rows and just need an approximate answer:

```sql
-- Approximate count (much faster on large tables)
SELECT count() * 10 AS estimated_rows
FROM etrm.market_data SAMPLE 0.1;

-- Approximate average (within ~3% accuracy for 10% sample)
SELECT avg(price) FROM etrm.market_data SAMPLE 0.1 WHERE area_id = 1;
```

### Task D3: Design a materialized view

For queries that run every morning, pre-compute the results:

```sql
-- Create a materialized view that auto-updates when market_data is inserted
CREATE MATERIALIZED VIEW etrm.mv_price_summary
ENGINE = AggregatingMergeTree()
ORDER BY (area_id, value_date)
AS SELECT
    area_id,
    toDate(value_datetime) AS value_date,
    avgState(price) AS avg_price,
    maxState(price) AS max_price,
    minState(price) AS min_price,
    countState() AS trade_count
FROM etrm.market_data
GROUP BY area_id, toDate(value_datetime);

-- Query it (much faster than querying raw data)
SELECT
    area_id,
    value_date,
    avgMerge(avg_price) AS avg_price,
    maxMerge(max_price) AS max_price,
    minMerge(min_price) AS min_price,
    countMerge(trade_count) AS count
FROM etrm.mv_price_summary
GROUP BY area_id, value_date
ORDER BY value_date DESC, area_id
LIMIT 20;
```

---

## Part E — Schema Evolution: ALTER TABLE in Production (15 min)

Production databases change constantly. Adding a column, changing a type, or adding a constraint — each has different risks across MSSQL and ClickHouse.

### Task E1: Add a column to MDM golden_record

The business wants to track counterparty **legal entity identifier (LEI)**. In MDM Postgres:

```sql
-- MDM Postgres: add a column
ALTER TABLE golden_record ADD COLUMN lei VARCHAR(20);

-- Verify
SELECT column_name, data_type FROM information_schema.columns
WHERE table_name = 'golden_record' ORDER BY ordinal_position;

-- Update a record
UPDATE golden_record SET lei = '5493001KJTIIGC8Y1R12' WHERE mdm_id = 'MDM-001';
```

**Downstream impact:** Every consumer of the `counterparty.updated` Kafka event now receives a JSON that *doesn't* include `lei` until the MDM service is updated to include it. Old consumers ignore unknown fields. This is **backwards-compatible** schema evolution.

### Task E2: Add a column to ClickHouse

```sql
-- ClickHouse: add a column with a default value
ALTER TABLE etrm.market_data ADD COLUMN IF NOT EXISTS bid_price Float64 DEFAULT 0;

-- Existing rows get the default value
SELECT price, bid_price FROM etrm.market_data LIMIT 5;

-- New inserts can include the column
INSERT INTO etrm.market_data
(value_date, value_datetime, issue_datetime, area_id, price, volume, source, currency, bid_price)
VALUES (today(), now(), now(), 1, 15.50, 100, 'SCHEMA_TEST', 'JPY', 15.45);

-- Verify
SELECT price, bid_price, source FROM etrm.market_data
WHERE source = 'SCHEMA_TEST';
```

**Key difference from MSSQL:** ClickHouse `ALTER TABLE ADD COLUMN` is instant (metadata-only). It doesn't rewrite existing data. Old rows return the default value. This is why ClickHouse schema evolution is much safer than MSSQL for large tables.

### Task E3: The dangerous schema change

```sql
-- MSSQL: what happens if you try to change a column type?
-- DON'T RUN THIS — just understand the risk:
-- ALTER TABLE trade ALTER COLUMN total_quantity INT;
-- This would FAIL if any existing value has decimals (e.g., 100.5 → can't fit in INT)
-- It would also lock the table for the duration of the rewrite
```

**Production rule:** Never change a column type in MSSQL during trading hours. Always:
1. Add a new column with the new type
2. Backfill it from the old column
3. Update the service to read from the new column
4. Drop the old column after verification

This is called the **expand and contract** pattern.

---

## Checkpoint: What You Should Be Able to Do

- [ ] Profile a ClickHouse query using `system.query_log`
- [ ] Explain the difference between FINAL and argMax approaches
- [ ] Create and verify a ClickHouse projection
- [ ] Read an MSSQL execution plan and identify table scans
- [ ] Add an index to MSSQL and measure the improvement
- [ ] Explain why batch inserts are critical for ClickHouse performance
- [ ] Use partition pruning and sampling for faster queries
- [ ] Design a materialized view for frequently-run reports
- [ ] Add a column to a production table (Postgres, ClickHouse) and understand downstream impact
- [ ] Explain the expand-and-contract pattern for dangerous schema changes

---

## What Makes This World-Class

Performance tuning is where you prove you understand the system, not just the syntax. The hierarchy:

1. **Junior:** writes a query that works
2. **Mid-level:** writes a query that works AND is correct (uses FINAL)
3. **Senior:** writes a query that is correct AND fast (uses projections, partition pruning, batch inserts)
4. **Staff/Principal:** designs the schema so queries are fast by default (partition keys, sort keys, materialized views)

The difference between a 20-minute P&L report and a 2-second one is usually 3-4 changes. Knowing which changes to make is what makes you invaluable.

# Lab 4 — P&L Investigation: End-to-End Scenario

**Prereqs:** Labs 1-3 complete.
**Time:** 45 minutes
**Goal:** Simulate a real on-the-job scenario — a trader questions a P&L number, you investigate.

---

## The Scenario

It's 9am. A trader messages you:

> "Hey, the P&L on trade TRD-2025-001 looks off. It's showing -¥120,000 unrealized but I thought the JEPX curve moved in our favour yesterday. Can you check?"

This is a real task you'll do. Here's how to approach it systematically.

---

## Step 1: Find the Trade (MSSQL)

Open DBeaver or Superset SQL Lab → ETRM MSSQL:

```sql
-- Get all details of the trade in question
SELECT
    t.trade_id,
    t.unique_id,
    cp.name         AS counterparty,
    tc.area_id,
    tc.settlement_mode,
    tc.product_type,
    tc.quantity     AS mw,
    tc.price        AS contracted_price,
    tc.price_denominator AS currency,
    tc.start_date,
    tc.end_date
FROM trade t
JOIN trade_component tc ON tc.trade_id = t.trade_id
JOIN counterparty cp    ON cp.counterparty_id = t.counterparty_id
WHERE t.unique_id = 'TRD-2025-001';
```

Note down:
- What area is it in?
- What is the contracted price?
- What period does it cover?
- Is it PHYSICAL or FINANCIAL?

If TRD-2025-001 doesn't exist in your sandbox, use whatever `unique_id` you see from:
```sql
SELECT unique_id FROM trade;
```

---

## Step 2: Check Current P&L (ClickHouse)

Open Superset SQL Lab → ETRM ClickHouse:

```sql
-- Get the P&L summary for this trade
SELECT
    trade_id,
    trade_ref,
    market_area,
    avg_contracted_price,
    total_realized_pnl,
    total_unrealized_pnl,
    total_pnl,
    settled_intervals,
    pending_intervals,
    last_updated
FROM etrm.vw_pnl_by_trade
WHERE trade_ref = 'TRD-2025-001';  -- use your actual trade_ref
```

Note the current P&L numbers and the `last_updated` timestamp.

---

## Step 3: Drill Into the Intervals (ClickHouse)

The trader says the curve moved in their favour. Let's check the interval-level data:

```sql
-- Show all intervals for this trade — latest version only
SELECT
    trade_ref,
    interval_start,
    delivery_date,
    delivery_hour,
    market_area,
    quantity,
    contracted_price,
    settle_price,
    mtm_price,
    valuation_price,
    interval_pnl,
    is_settled,
    snapshot_time
FROM etrm.vw_trade_intervals_flat
WHERE trade_ref = 'TRD-2025-001'
ORDER BY interval_start
LIMIT 50;
```

**What to look for:**
- Are any intervals settled (`is_settled = 1`)? Those have real `settle_price`.
- For open intervals, is `mtm_price` higher or lower than `contracted_price`?
- If we SOLD power: `interval_pnl = (mtm_price - contracted_price) * quantity` — negative means market rose above our contracted price (we're losing vs market)

---

## Step 4: Check What the MTM Curve Looks Like (ClickHouse)

The trader claims the curve moved in their favour. Let's verify:

```sql
-- MTM forward curve for JEPX (curve_id=1 for JEPX in this sandbox)
SELECT
    value_date,
    mtm_price,
    as_of
FROM etrm.vw_mtm_curve_latest
WHERE curve_id = 1  -- adjust based on what curves exist
ORDER BY value_date
LIMIT 30;
```

Also check current market prices:
```sql
SELECT
    value_date,
    market_area,
    latest_price,
    as_of
FROM etrm.vw_market_prices_latest
WHERE market_area = 'JEPX'
ORDER BY value_date
LIMIT 10;
```

**Compare:** Is the current market/MTM price higher or lower than the contracted price on the trade?

---

## Step 5: Check the History (Time Travel)

The trader says the curve moved yesterday. Let's see what the data showed at different points:

```sql
-- What was the MTM price for JEPX yesterday vs today?
SELECT
    issue_datetime,
    area_id,
    argMax(price, issue_datetime) OVER (PARTITION BY toDate(issue_datetime), area_id) AS daily_price
FROM etrm.market_data
WHERE area_id = 1
  AND issue_datetime >= now() - INTERVAL 2 DAY
ORDER BY issue_datetime DESC
LIMIT 20;
```

Or more simply:
```sql
-- Latest price published each day (to see trend)
SELECT
    toDate(issue_datetime)          AS date,
    area_id,
    argMax(price, issue_datetime)   AS closing_price,
    max(issue_datetime)             AS last_update
FROM etrm.market_data
WHERE area_id = 1
GROUP BY toDate(issue_datetime), area_id
ORDER BY date DESC
LIMIT 7;
```

---

## Step 6: Formulate Your Answer

Based on your investigation, draft a response to the trader. Use this structure:

```
Trade: TRD-2025-001
Counterparty: [name]
Market: [JEPX/NEM/NZEM]
Contracted price: [price] [currency]/MWh
Current MTM price: [price] (as of [timestamp])

P&L breakdown:
- Settled intervals: [X] → realized P&L: [amount]
- Open intervals: [X] → unrealized P&L: [amount]
- Total P&L: [amount]

Why the unrealized P&L is [positive/negative]:
[Your explanation — e.g. "We sold at ¥15 but current JEPX MTM is ¥18,
so for each open interval we're losing ¥3/kWh × 100 MW"]

Curve movement:
[Did it move in their favour or not? What does the data show?]
```

---

## Extension: Reproduce This in Superset

Build a dedicated drill-down dashboard for trade investigation:

1. **Chart 1:** Big Number — Total P&L for the selected trade
2. **Chart 2:** Line chart — interval P&L over time (x=delivery_date, y=sum of interval_pnl)
3. **Chart 3:** Table — all intervals with contracted vs MTM price
4. **Filter:** Trade reference (dropdown) — so you can switch between trades

This becomes your go-to tool every time a trader questions a P&L number.

---

## Checkpoint: What You Should Be Able to Do

- [ ] Find a trade in MSSQL and extract its key details
- [ ] Find the P&L summary in ClickHouse for that trade
- [ ] Drill into interval-level data to see where the P&L comes from
- [ ] Check the MTM curve and market prices
- [ ] Explain P&L using the formula: `(valuation_price - contracted_price) × quantity`
- [ ] Use `issue_datetime` to understand when data was last updated
- [ ] Write a clear response to a trader's P&L question

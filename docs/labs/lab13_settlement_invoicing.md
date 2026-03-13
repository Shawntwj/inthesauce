# Lab 13 — Settlement & Invoice Matching: Where the Money Actually Flows

**Prereqs:** Labs 1, 4 complete. All containers running.
**Time:** 60-75 minutes
**Goal:** Understand the settlement lifecycle — from delivered energy to invoices to matched payments — and build the queries that a settlement analyst uses daily.

---

## Why This Matters

Trading gets the glory. Settlement is where the money actually moves. A settlement analyst at an energy trading firm reconciles millions of dollars of invoices every month. An error here means you either overpay a counterparty or underbill them — both are career-limiting.

This is also one of the most common interview topics for energy tech roles: "explain the settlement process" or "how would you detect an invoice mismatch?"

---

## Scenario

**End of month. February 2025 delivery period is over for TRADE-JP-001.**

The settlement team needs to:
1. Calculate what we owe / are owed based on delivered energy
2. Generate our invoice
3. Compare it against the counterparty's invoice
4. Flag mismatches for investigation

---

## Part A — Calculate Settlement Amount (20 min)

### Task A1: Sum up delivered energy for a settled trade

A trade settles when its delivery period ends. For TRADE-JP-001 (Feb 1-28, JEPX, STANDARD):

```sql
-- ClickHouse: total delivered quantity × settlement price
SELECT
    trade_id,
    unique_id AS trade_ref,
    count(*) AS settled_intervals,
    sum(quantity) AS total_mwh,
    avg(COALESCE(settle_price, price)) AS avg_settlement_price,
    sum(quantity * COALESCE(settle_price, price)) AS gross_settlement_value,
    currency
FROM etrm.transaction_exploded FINAL
WHERE trade_id = 1
  AND settle_price IS NOT NULL  -- only settled intervals
GROUP BY trade_id, unique_id, currency;
```

**Questions:**
- What is `total_mwh`? (Hint: each interval is 30 min at X MW, so MWh = MW × 0.5)
- Why do we use `COALESCE(settle_price, price)`? (Fallback to contracted price if no settlement price published yet)

### Task A2: Compare contracted vs actual value

```sql
-- ClickHouse
SELECT
    trade_id,
    unique_id AS trade_ref,

    -- What we contracted
    sum(quantity * price) AS contracted_value,

    -- What actually settled
    sum(quantity * COALESCE(settle_price, price)) AS settled_value,

    -- The difference (our realized P&L from settlement)
    sum(quantity * (COALESCE(settle_price, price) - price)) AS settlement_pnl,

    currency
FROM etrm.transaction_exploded FINAL
WHERE trade_id = 1
GROUP BY trade_id, unique_id, currency;
```

**Key insight:** `settlement_pnl` = what we actually made/lost. This is REALIZED P&L. It's locked in — no more mark-to-market uncertainty.

### Task A3: Generate an invoice line

Based on the settlement calculation, generate what our invoice would look like:

```sql
-- What the invoice would contain
SELECT
    'INV-2025-02-001' AS invoice_number,
    'TRADE-JP-001' AS trade_ref,
    '2025-02-01' AS delivery_start,
    '2025-02-28' AS delivery_end,
    sum(quantity * 0.5) AS total_mwh_delivered,  -- 30-min intervals, so MW × 0.5 = MWh
    avg(COALESCE(settle_price, price)) AS avg_price,
    sum(quantity * 0.5 * COALESCE(settle_price, price)) AS invoice_amount,
    currency,
    'PENDING' AS status
FROM etrm.transaction_exploded FINAL
WHERE trade_id = 1
  AND settle_price IS NOT NULL
GROUP BY currency;
```

---

## Part B — Invoice Matching (20 min)

### Task B1: Understand the invoice table

```sql
-- MSSQL: current invoices
SELECT
    i.invoice_id,
    i.invoice_number,
    i.trade_id,
    t.unique_id AS trade_ref,
    t.counterparty_mdm_id,
    i.amount,
    i.currency,
    i.invoice_date,
    i.due_date,
    i.status,
    i.matched_amount,
    i.match_status,
    i.amount - ISNULL(i.matched_amount, 0) AS unmatched_amount
FROM invoice i
JOIN trade t ON t.trade_id = i.trade_id
ORDER BY i.invoice_date DESC;
```

### Task B2: Simulate receiving a counterparty invoice

In a real system, the counterparty sends their invoice. You need to match it against yours. The seed data already has our invoice (INV-2025-02-001 for ¥65,000). Now simulate receiving the counterparty's version:

```sql
-- MSSQL: Insert a "received" counterparty invoice (their amount differs slightly from ours)
INSERT INTO invoice (trade_id, component_id, invoice_number, amount, currency, invoice_date, due_date, status)
VALUES (1, 1, 'CPTY-INV-TEC-202502', 65500.00, 'JPY', '2025-03-01', '2025-03-31', 'PENDING');
```

### Task B3: Match invoices with tolerance

The key insight: **invoices never match exactly.** There are rounding differences, timing differences, and legitimate disputes. You need a tolerance threshold.

```sql
-- MSSQL: Compare our invoice vs counterparty's
DECLARE @our_amount DECIMAL(18,2);
DECLARE @their_amount DECIMAL(18,2) = 65500.00;
DECLARE @tolerance_pct DECIMAL(5,2) = 1.0;  -- 1% tolerance

-- Calculate our amount from ClickHouse data (you'd normally have this stored)
SET @our_amount = 65000.00;  -- Example value

SELECT
    @our_amount AS our_invoice,
    @their_amount AS their_invoice,
    @their_amount - @our_amount AS difference,
    ABS(@their_amount - @our_amount) / @our_amount * 100 AS difference_pct,
    CASE
        WHEN ABS(@their_amount - @our_amount) / @our_amount * 100 <= @tolerance_pct
        THEN 'MATCHED'
        WHEN ABS(@their_amount - @our_amount) / @our_amount * 100 <= @tolerance_pct * 3
        THEN 'PARTIAL_MATCH'
        ELSE 'MISMATCH'
    END AS match_result;
```

### Task B4: Update invoice status

```sql
-- MSSQL: Update the match result
UPDATE invoice
SET matched_amount = 65000.00,
    match_status = 'PARTIAL',
    status = 'MATCHED'
WHERE invoice_number = 'CPTY-INV-TEC-202502';
```

---

## Part C — Build a Settlement Dashboard (20 min)

### Task C1: Invoice status breakdown

In Superset SQL Lab → ETRM MSSQL:

```sql
-- For a pie chart: Invoice Status Breakdown
SELECT
    status,
    count(*) AS count,
    SUM(amount) AS total_amount
FROM invoice
GROUP BY status;
```

Create a pie chart from this query and add it to a new "Settlement" dashboard.

### Task C2: Overdue invoices

```sql
SELECT
    i.invoice_number,
    t.unique_id AS trade_ref,
    t.counterparty_mdm_id,
    i.amount,
    i.currency,
    i.due_date,
    DATEDIFF(DAY, i.due_date, GETUTCDATE()) AS days_overdue,
    i.status,
    i.match_status
FROM invoice i
JOIN trade t ON t.trade_id = i.trade_id
WHERE i.due_date < GETUTCDATE()
  AND i.status != 'PAID'
ORDER BY days_overdue DESC;
```

### Task C3: Settlement by counterparty (cross-database)

This requires data from both MSSQL (invoices, trade references) and MDM Postgres (counterparty names, credit limits). In production, your Go service would join this. For Superset, you'd create a denormalized view:

```sql
-- MSSQL: Settlement summary by counterparty MDM ID
SELECT
    t.counterparty_mdm_id,
    COUNT(DISTINCT i.invoice_id) AS invoice_count,
    SUM(CASE WHEN i.status = 'PENDING' THEN i.amount ELSE 0 END) AS pending_amount,
    SUM(CASE WHEN i.status = 'MATCHED' THEN i.amount ELSE 0 END) AS matched_amount,
    SUM(CASE WHEN i.match_status = 'MISMATCH' THEN 1 ELSE 0 END) AS mismatch_count,
    SUM(i.amount) AS total_invoiced
FROM invoice i
JOIN trade t ON t.trade_id = i.trade_id
GROUP BY t.counterparty_mdm_id;
```

Then look up the names in MDM Postgres:
```sql
-- MDM Postgres: counterparty details
SELECT mdm_id, canonical_name, credit_limit, currency FROM golden_record;
```

---

## Part D — Settlement Edge Cases (15 min)

### Task D1: Partial delivery

What if a trade was supposed to deliver 100 MW for 48 half-hours but only 45 half-hours have settlement prices?

```sql
-- ClickHouse: Find trades with incomplete settlement
SELECT
    trade_id,
    unique_id,
    countIf(settle_price IS NOT NULL) AS settled_slots,
    countIf(settle_price IS NULL) AS unsettled_slots,
    count(*) AS total_slots,
    round(countIf(settle_price IS NOT NULL) * 100.0 / count(*), 1) AS settlement_pct
FROM etrm.transaction_exploded FINAL
WHERE interval_start < now()  -- only past intervals
GROUP BY trade_id, unique_id
HAVING unsettled_slots > 0
ORDER BY unsettled_slots DESC;
```

**Question:** What does it mean when a past interval has no settlement price? Options:
1. The exchange hasn't published the price yet (normal, wait)
2. The data feed is broken (incident — check the feed)
3. It was a non-delivery day (public holiday not in the profile)

### Task D2: Imbalance charges

For PHYSICAL trades, if you don't deliver exactly what you promised, the grid operator charges an imbalance fee:

```sql
-- Conceptual query: imbalance = contracted - actual
-- In a real system, you'd have actual metered delivery data
SELECT
    trade_id,
    interval_start,
    quantity AS contracted_mw,
    -- actual_mw would come from a meter data feed
    quantity * 0.95 AS simulated_actual_mw,  -- simulate 5% under-delivery
    quantity - (quantity * 0.95) AS imbalance_mw,
    (quantity - (quantity * 0.95)) * settle_price * 1.5 AS imbalance_cost  -- 150% penalty
FROM etrm.transaction_exploded FINAL
WHERE trade_id = 2  -- PHYSICAL trade (NEM)
  AND settle_price IS NOT NULL
LIMIT 10;
```

**Key insight:** Physical trades carry delivery risk that financial trades don't. This is why settlement_mode matters.

---

## Checkpoint: What You Should Be Able to Do

- [ ] Calculate the settlement amount for a completed delivery period
- [ ] Explain the difference between contracted value and settled value
- [ ] Match two invoices with a tolerance threshold
- [ ] Identify and investigate invoice mismatches
- [ ] Build a settlement status dashboard
- [ ] Explain partial delivery and imbalance charges
- [ ] Describe the full lifecycle: trade → delivery → settlement → invoice → payment

---

## Reflection: Real-World Complexity

In a real firm, settlement involves:
- **Netting** — if you have 10 trades with the same counterparty, you net them into one invoice
- **GST/VAT** — tax calculations vary by jurisdiction (JEPX: consumption tax, NEM: GST, NZEM: GST)
- **FX conversion** — if the invoice is in JPY but your books are in AUD
- **Dispute resolution** — when mismatches exceed tolerance, the settlement team negotiates
- **Regulatory reporting** — AEMO (NEM), ASX (clearing), JEPX (pool settlement)

Each of these is a system in itself. Understanding the base flow from this lab puts you ahead of 90% of candidates.

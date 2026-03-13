# Lab 11 — Incident Response: "The P&L is Wrong"

**Prereqs:** Labs 1, 4, 6 complete. All containers running.
**Time:** 60-90 minutes
**Goal:** Simulate a real production incident end-to-end — from alert to root cause to fix to postmortem.

---

## Why This Matters

The #1 skill that separates senior from junior engineers isn't writing code. It's **diagnosing a problem under pressure when a trader is shouting**. This lab simulates the most common incident in energy trading: "the P&L number doesn't match what I expected."

---

## Scenario

**8:47 AM — Slack message from the head trader:**

> "The morning P&L report shows TRADE-JP-001 has a P&L of -¥50,000 but the JEPX curve moved in our favour overnight. This should be positive. Something is broken. Fix it before the 9am risk meeting."

You have 13 minutes.

---

## Part A — Triage (5 min)

**Rule #1: Don't guess. Look at the data.**

### Task A1: Confirm the reported number

Open Superset SQL Lab → ETRM ClickHouse:
```sql
SELECT
    trade_id,
    unique_id       AS trade_ref,
    market_area,
    total_realized_pnl,
    total_unrealized_pnl,
    total_pnl,
    settled_intervals,
    pending_intervals,
    last_updated
FROM etrm.vw_pnl_by_trade
WHERE unique_id = 'TRADE-JP-001';
```

Write down the numbers. Is `total_pnl` actually negative?

### Task A2: Check the contracted price

Open MSSQL:
```sql
SELECT t.unique_id, tc.price, tc.quantity, tc.start_date, tc.end_date,
       tc.area_id, tc.settlement_mode
FROM trade t
JOIN trade_component tc ON tc.trade_id = t.trade_id
WHERE t.unique_id = 'TRADE-JP-001';
```

Note: **contracted_price = 11.50 JPY**. The trader says the curve moved in their favour — meaning the market price went UP above 11.50.

### Task A3: Check the current market price

```sql
-- ClickHouse
SELECT
    value_datetime,
    latest_price,
    currency,
    as_of
FROM etrm.vw_market_prices_latest
WHERE area_id = 1
ORDER BY value_datetime DESC
LIMIT 5;
```

**Key question:** Is the latest market price above or below 11.50? If it's above 11.50 and the P&L is negative, something is wrong with the calculation, not the data.

---

## Part B — Deep Dive (10 min)

### Task B1: Check interval-level P&L

The aggregate P&L is the SUM of all interval P&Ls. Let's look at the individual slots:

```sql
-- ClickHouse
SELECT
    interval_start,
    quantity,
    contracted_price,
    settle_price,
    mtm_price,
    valuation_price,
    realized_pnl,
    unrealized_pnl,
    interval_pnl,
    is_settled,
    snapshot_time
FROM etrm.vw_trade_intervals_flat
WHERE trade_ref = 'TRADE-JP-001'
ORDER BY interval_start
LIMIT 50;
```

**What to look for:**
- Are there intervals where `valuation_price < contracted_price`? That's where the loss comes from.
- Are there intervals where `settle_price` is NULL but `mtm_price` is also NULL? That means no valuation at all.
- Is `snapshot_time` (= `issue_datetime`) recent? If it's from 3 days ago, the MTM prices are stale.

### Task B2: Time-travel — what changed overnight?

This is the power move. ClickHouse keeps all versions via `issue_datetime`:

```sql
-- WITHOUT FINAL — shows all historical versions
SELECT
    interval_start,
    mtm_price,
    unrealized_pnl,
    issue_datetime
FROM etrm.transaction_exploded
WHERE trade_id = 1
  AND interval_start = '2025-02-15 00:00:00'
ORDER BY issue_datetime DESC;
```

**If you see multiple rows for the same interval:** the MTM price was updated. Compare the old vs new price. Did it go up or down?

### Task B3: Check the MTM curve source

```sql
-- ClickHouse: what curve is being used?
SELECT
    curve_id,
    value_datetime,
    mtm_price,
    source,
    as_of
FROM etrm.vw_mtm_curve_latest
WHERE curve_id = 1  -- JEPX curve
ORDER BY value_datetime DESC
LIMIT 10;
```

**Common root causes:**
1. **Stale curve** — the overnight curve wasn't loaded (check `as_of` timestamp)
2. **Wrong curve** — the trade is using curve_id=4 (in-house model) instead of curve_id=1 (exchange)
3. **Data quality** — a price of 0.00 or 999.99 got loaded (bad feed)
4. **Timing** — the curve was loaded at 6pm but the overnight move happened at 2am

---

## Part C — Inject a Fault & Fix It (15 min)

Now let's deliberately break the P&L and fix it — the way a production issue would play out.

### Task C1: Inject bad market data

```sql
-- ClickHouse: insert a bad price (simulating a corrupt feed)
INSERT INTO etrm.market_data
(value_date, value_datetime, issue_datetime, area_id, price, volume, source, currency)
VALUES
(today(), now(), now(), 1, 0.01, 100.0, 'BAD_FEED', 'JPY');
```

### Task C2: Verify the damage

```sql
SELECT area_id, argMax(price, issue_datetime) AS latest_price, max(issue_datetime)
FROM etrm.market_data
WHERE area_id = 1
GROUP BY area_id;
```

The latest JEPX price is now 0.01 — this would make every JEPX trade's unrealized P&L massively negative.

### Task C3: Fix it

In ClickHouse, you can't DELETE. You insert a **correction row** with a newer `issue_datetime`:

```sql
INSERT INTO etrm.market_data
(value_date, value_datetime, issue_datetime, area_id, price, volume, source, currency)
VALUES
(today(), now(), now() + INTERVAL 1 SECOND, 1, 15.80, 100.0, 'MANUAL_CORRECTION', 'JPY');
```

Verify:
```sql
SELECT area_id, argMax(price, issue_datetime) AS latest_price,
       argMax(source, issue_datetime) AS source
FROM etrm.market_data
WHERE area_id = 1
GROUP BY area_id;
```

**Expected:** `latest_price = 15.80`, `source = MANUAL_CORRECTION`.

### Task C4: Add a data quality check

How do you prevent this from happening again? Write a ClickHouse query that detects anomalous prices:

```sql
-- Detect prices that are > 3 standard deviations from the mean
SELECT
    area_id,
    value_datetime,
    price,
    source,
    issue_datetime,
    avg(price) OVER (PARTITION BY area_id ORDER BY value_datetime
                     ROWS BETWEEN 48 PRECEDING AND 1 PRECEDING) AS rolling_avg,
    stddevPop(price) OVER (PARTITION BY area_id ORDER BY value_datetime
                           ROWS BETWEEN 48 PRECEDING AND 1 PRECEDING) AS rolling_std
FROM etrm.market_data FINAL
WHERE area_id = 1
ORDER BY value_datetime DESC
LIMIT 20;
```

**This is what a production data quality pipeline does.** Flag any price where `abs(price - rolling_avg) > 3 * rolling_std`.

---

## Part D — Write the Postmortem (15 min)

Every incident gets a postmortem. Write one. This is a real skill that gets you promoted.

### Template:

```markdown
## Incident: Incorrect JEPX P&L — TRADE-JP-001
**Date:** [today]
**Duration:** 13 minutes (8:47 AM — 9:00 AM)
**Severity:** P2 — incorrect risk numbers reported to trading desk
**Impact:** JEPX P&L misreported by ¥X. No trades were booked against incorrect prices.

### Timeline
- 8:47 — Trader reports P&L looks wrong for TRADE-JP-001
- 8:49 — Confirmed: total_pnl shows -¥50K, expected positive
- 8:52 — Root cause identified: bad market data feed inserted price of 0.01
- 8:55 — Manual correction inserted with source='MANUAL_CORRECTION'
- 8:57 — P&L re-verified, correct price restored
- 9:00 — Trader confirmed numbers look correct

### Root Cause
A corrupt data feed inserted a JEPX price of ¥0.01 at [timestamp].
Because ClickHouse uses argMax(price, issue_datetime), this became the
"latest" price and all unrealized P&L calculations used it.

### Fix
Inserted correction row with newer issue_datetime and correct price.

### Action Items
- [ ] Add price anomaly detection (3-sigma check) to market data pipeline
- [ ] Add Grafana alert for market prices outside expected range
- [ ] Add source validation — reject prices from unknown sources
- [ ] Add price change magnitude limit — reject changes > 50% in a single update
```

---

## Part E — Build a Grafana Alert (15 min)

### Task E1: Create a data quality panel

Open Grafana → New Dashboard → Add Panel:

- **Datasource:** ClickHouse
- **Query:**
```sql
SELECT
    now() as time,
    area_id,
    argMax(price, issue_datetime) as latest_price,
    argMax(source, issue_datetime) as source
FROM etrm.market_data
GROUP BY area_id
```
- **Alert condition:** `latest_price < 1.0 OR latest_price > 500.0`
- **Evaluation:** every 30 seconds
- **For:** 1 minute (must be anomalous for 1 minute before alerting)

### Task E2: Trigger the alert

Insert another bad price and watch the alert fire:
```sql
INSERT INTO etrm.market_data
(value_date, value_datetime, issue_datetime, area_id, price, volume, source, currency)
VALUES (today(), now(), now(), 1, 0.001, 100.0, 'BAD_FEED_2', 'JPY');
```

Watch Grafana → Alerting → Alert Rules. Does your rule fire?

Fix it and watch it resolve:
```sql
INSERT INTO etrm.market_data
(value_date, value_datetime, issue_datetime, area_id, price, volume, source, currency)
VALUES (today(), now(), now() + INTERVAL 1 SECOND, 1, 15.50, 100.0, 'CORRECTION_2', 'JPY');
```

---

## Checkpoint: What You Should Be Able to Do

- [ ] Triage a P&L discrepancy in under 5 minutes
- [ ] Use time-travel queries to see what changed and when
- [ ] Inject and correct bad data in ClickHouse (without DELETE)
- [ ] Write a postmortem that identifies root cause and action items
- [ ] Build a Grafana alert that catches data quality issues automatically
- [ ] Explain to a non-technical trader why the P&L was wrong and what you did to fix it
- [ ] Correlate timestamps across MSSQL, ClickHouse, and MDM Postgres to trace a data issue

---

## Part F — Config-Tracing Under Pressure (10 min)

### Scenario: "Grafana MSSQL panels show no data"

A colleague says Grafana can't query MSSQL. Diagnose it systematically:

### Task F1: Trace the Grafana → MSSQL connection

1. Check Grafana datasource config:
```bash
cat infra/grafana/provisioning/datasources/datasources.yml | grep -A 5 mssql
```
Note the host, port, and password.

2. Check what password MSSQL is actually running with:
```bash
grep SA_PASSWORD .env
```

3. Check the Makefile for any hardcoded passwords:
```bash
grep -i 'pass' Makefile
```

4. **Do they all match?** If you find different passwords in different files, you've found a real bug that exists in many production systems.

### Task F2: The debugging checklist

When any service can't connect to another, run through this:

| Step | Command | What You're Checking |
|------|---------|---------------------|
| 1. Is the target running? | `docker compose ps` | Container status (Up, Exited, Restarting) |
| 2. Is it healthy? | `docker inspect --format '{{.State.Health.Status}}' <container>` | Healthcheck passing? |
| 3. Can the client reach it? | `docker exec <client> cat /dev/null > /dev/tcp/<host>/<port>` | Network connectivity |
| 4. Is the config correct? | Check credentials, host, port in both sides | Config mismatch |
| 5. What do the logs say? | `docker compose logs <service> --tail 50` | Error messages |

**This checklist works for any distributed system, not just Docker.** In production on AWS, you'd replace `docker inspect` with `aws ecs describe-tasks` and `docker exec` with `kubectl exec`, but the thinking is identical.

---

## Why This Makes You World-Class

Most engineers can fix bugs. What gets you promoted is:

1. **Speed of diagnosis** — you knew exactly where to look (interval-level data, then issue_datetime, then source)
2. **Communication** — you told the trader what happened in business terms, not SQL
3. **Prevention** — you built the alert so it never happens silently again
4. **Documentation** — your postmortem means the next person doesn't start from zero
5. **Composure** — you didn't panic when the trader said "fix it before 9am"

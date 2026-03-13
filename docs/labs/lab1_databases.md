# Lab 1 — Databases: MSSQL + ClickHouse + MDM Postgres

**Prereqs:** Docker stack running (`make up`). DBeaver installed.
**Time:** 45-60 minutes
**Goal:** Be comfortable querying all three databases, understand the difference in how they behave.

---

## Setup (MUST DO FIRST)

Azure SQL Edge does NOT auto-run init scripts on startup (unlike Postgres and ClickHouse which do). You need to run the MSSQL init manually.

### Step 1: Initialise MSSQL

**Option A — via Makefile (recommended):**
```bash
make mssql-init
```

**Option B — via DBeaver:**
Open DBeaver, connect to MSSQL (`localhost:1433`, user `sa`, password `YourStr0ngPass1`). Open the file `scripts/init_mssql.sql` and execute the entire script. This creates the `etrm` database, all tables, and seed data (including invoices for Lab 13).

> **Note:** ClickHouse and MDM Postgres auto-initialise on first `make up`. No manual step needed for those.

### Step 2: Create reporting views
```bash
make powerbi-views
```
Then in DBeaver (connected to MSSQL, database `etrm`), open and execute `scripts/powerbi_views_mssql.sql`.

### Step 3: Verify everything
```bash
make check-health
```

---

## Part A — MSSQL (15 min)

Connect in DBeaver: `localhost:1433`, user `sa`, password `YourStr0ngPass1`, database `etrm`.

### Task A1: Explore the schema
1. Expand `etrm` → `Tables` in the DBeaver tree
2. Right-click `trade` → View Data — how many rows do you see? Note the `counterparty_mdm_id` column (e.g. `MDM-001`).
3. Counterparty data is no longer in MSSQL — it lives in MDM Postgres (see Part D below).

**Expected:** 5 trades, 5 trade_components (counterparty details are in MDM Postgres)

### Task A2: Run the trade blotter query
Copy this into a DBeaver SQL editor and run it:
```sql
SELECT
    t.unique_id         AS trade_ref,
    t.counterparty_mdm_id,
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
WHERE t.is_active = 1
ORDER BY t.trade_at_utc DESC;
```

**Questions to answer:**
- Which counterparty MDM ID has the most trades? (MDM-001=Tokyo Energy Corp/TEC, MDM-002=AUS Grid Partners/AGP, MDM-003=NZ Renewable Trust/NZRT)
- What markets are represented? (area_id 1=JEPX, 2=NEM, 3=NZEM)
- Is any trade FINANCIAL vs PHYSICAL?

### Task A3: View counterparties in MDM Postgres
Counterparties are managed in MDM Postgres, not MSSQL. Connect to MDM Postgres (see Part D) and run:
```sql
SELECT mdm_id, canonical_name, short_code, credit_limit, currency, is_active
FROM golden_record;
```

**Expected:** 3 rows — MDM-001 (Tokyo Energy Corp), MDM-002 (AUS Grid Partners), MDM-003 (NZ Renewable Trust).

### Task A4: Check credit exposure
Run the exposure query in MSSQL:
```sql
SELECT
    t.counterparty_mdm_id,
    COUNT(DISTINCT t.trade_id) AS open_trades,
    SUM(tc.quantity * tc.price * DATEDIFF(day, tc.start_date, tc.end_date)) AS total_notional
FROM trade t
LEFT JOIN trade_component tc ON tc.trade_id = t.trade_id
WHERE t.is_active = 1
GROUP BY t.counterparty_mdm_id
ORDER BY total_notional DESC;
```

Then compare against credit limits from MDM Postgres:
```sql
-- Run in MDM Postgres
SELECT mdm_id, canonical_name, credit_limit, currency FROM golden_record WHERE is_active = true;
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
SELECT t.trade_id, t.unique_id, t.counterparty_mdm_id
FROM trade t;
```
Note the trade_ids and counterparty MDM IDs.

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

## Part D — MDM Postgres (10 min)

Connect in DBeaver: `localhost:5432`, user `mdm`, password `mdmpass`, database `mdm`.

The MDM (Master Data Management) service manages counterparty golden records. This is the source of truth for counterparty data — MSSQL trades reference it via `counterparty_mdm_id`.

### Task D1: Browse golden records
```sql
SELECT mdm_id, canonical_name, short_code, credit_limit, currency, is_active, data_steward
FROM golden_record;
```

**Expected:** 3 rows — MDM-001 (Tokyo Energy Corp / TEC), MDM-002 (AUS Grid Partners / AGP), MDM-003 (NZ Renewable Trust / NZRT).

### Task D2: Preview the MDM inbox

MDM Postgres has seed data showing records from multiple source systems at various match stages:

```sql
SELECT source_system, raw_name, match_status, match_score, matched_mdm_id
FROM incoming_record
ORDER BY record_id;
```

**Expected:** 6 rows — some AUTO_MERGED, some QUEUED (waiting for human review), one NEW (unknown entity). You'll work with these in detail in Lab 9.

### Task D3: Understand the MDM-to-MSSQL relationship
The `trade` table in MSSQL has a `counterparty_mdm_id VARCHAR(50)` column that maps to `golden_record.mdm_id` in MDM Postgres. There is no foreign key across databases — the link is maintained by convention and the MDM service publishes `counterparty.updated` Kafka events when golden records change.

---

## Part E — Debug Challenge: When Things Go Wrong (10 min)

Infra experts spend 80% of their time debugging. This section teaches the technique.

### Task E1: Investigate a container from the outside

```bash
# What is the container's IP address and what networks is it on?
docker inspect etrm-mssql --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'

# What environment variables does it see?
docker inspect etrm-mssql --format '{{range .Config.Env}}{{println .}}{{end}}'

# Is the container healthy? What does the healthcheck say?
docker inspect etrm-mssql --format '{{.State.Health.Status}}'
```

### Task E2: Investigate from inside a container

```bash
# Shell into the ClickHouse container and poke around
docker exec -it etrm-clickhouse bash

# Inside the container: can you reach MSSQL?
cat /dev/null > /dev/tcp/mssql/1433 && echo "MSSQL reachable" || echo "MSSQL unreachable"

# Inside the container: can you reach MDM Postgres?
cat /dev/null > /dev/tcp/mdm-postgres/5432 && echo "Postgres reachable" || echo "Postgres unreachable"

# Exit
exit
```

### Task E3: Read container logs to diagnose issues

```bash
# Check if MSSQL started cleanly
docker compose logs mssql --tail 30

# Check if ClickHouse init script ran
docker compose logs clickhouse --tail 30

# Check if MDM Postgres seed data loaded
docker compose logs mdm-postgres --tail 30
```

**What to look for:** "ERROR" or "FATAL" lines. Timestamp of startup. Whether the init scripts completed.

### Task E4: The config-tracing technique

When something doesn't connect, the technique is: **trace the config from the client to the server.**

Example: "Grafana can't connect to MSSQL." Trace:
1. Open `infra/grafana/provisioning/datasources/datasources.yml` — what host, port, password does Grafana use?
2. Open `.env` — what password is MSSQL actually set to?
3. Open `docker-compose.yml` — what port is MSSQL exposing?
4. Do they all match? If not, you found your bug.

**Exercise:** Open all 3 files and verify the MSSQL password is consistent. This is the #1 real-world debugging technique for distributed systems: when A can't talk to B, check A's config, check B's config, check the network between them.

---

## Checkpoint: What You Should Be Able to Do

- [ ] Connect DBeaver to MSSQL, ClickHouse, and MDM Postgres
- [ ] Explain why MSSQL uses `JOIN` and ClickHouse uses `argMax`
- [ ] Run a trade blotter query and read the results
- [ ] Explain what `FINAL` does and when to use it
- [ ] Insert a new row into ClickHouse and verify `argMax` returns it
- [ ] Run queries in Superset SQL Lab against both databases
- [ ] Query the MDM incoming_record table and explain what each match_status means
- [ ] Use `docker inspect` and `docker exec` to investigate a container
- [ ] Read container logs and identify errors
- [ ] Trace a connection failure across config files (the config-tracing technique)

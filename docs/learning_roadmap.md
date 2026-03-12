# Learning Roadmap — Reverse Engineering the ETRM Stack

This document breaks down how to learn this stack from the ground up.
Each section answers: **what it is, why it exists, what to learn, and what to build**.

---

## How to Use This Document

Work through the layers bottom-up. Each layer depends on the one before it.
You already have a running sandbox — use it to experiment, break things, and observe.

```
Layer 6: Business Reporting (Superset / Power BI)   ← you are here
Layer 5: Monitoring (Grafana / Prometheus)
Layer 4: Go Service Layer (trade logic, APIs)
Layer 3: Messaging (Kafka)
Layer 2: Databases (MSSQL + ClickHouse)
Layer 1: Infrastructure (Docker, Terraform, LocalStack)
```

---

## Layer 1 — Infrastructure

### What It Is
Docker runs all services as isolated containers. Terraform provisions cloud resources (S3 buckets, VPC). LocalStack fakes AWS locally so you don't pay real money.

### Why It Exists
Energy trading firms use cloud infra (AWS/Azure) for scalability and disaster recovery. Terraform ensures infra is reproducible — not click-ops.

### What to Learn

**Docker:**
- What is a container vs a VM?
- What does `docker-compose.yml` do? Read through the one in this repo.
- What is a `healthcheck`? Why do our containers have them?
- What is a Docker volume? Why does MSSQL use one?
- What is a Docker network? Why can `superset` container reach `mssql` by hostname?

**Terraform:**
- What is Infrastructure as Code?
- Read `infra/terraform/main.tf` — what resources does it create?
- What is `terraform plan` vs `terraform apply`?
- What is a Terraform state file?

### Exercises
1. Run `docker compose ps` — identify what each port does
2. Run `docker compose logs mssql` — see how the container started
3. `docker exec -it etrm-clickhouse bash` — explore inside a container
4. Read `docker-compose.yml` top to bottom — understand every field
5. Run `cd infra/terraform && terraform plan` — read what it would create
6. Add a new S3 bucket to `main.tf` and apply it

---

## Layer 2 — Databases

### What It Is
Two databases with different jobs:
- **MSSQL** — transactional, source of truth for trades (ACID, row-by-row updates)
- **ClickHouse** — analytics, append-only time-series (fast aggregations, no updates)

### Why It Exists
You cannot use one database for both jobs in a real trading firm. MSSQL handles the "did this trade happen?" question. ClickHouse handles the "what is my P&L right now across 10,000 half-hour intervals?" question. Trying to do the latter in MSSQL would be too slow.

### What to Learn

**MSSQL:**
- What is a PRIMARY KEY, FOREIGN KEY, IDENTITY column?
- What is a JOIN? Write a query that joins `trade` → `trade_component` → `counterparty`
- What is a transaction (`BEGIN TRAN`, `COMMIT`, `ROLLBACK`)?
- What is an INDEX and why does it speed up queries?
- What is a VIEW and why do we create flat views for reporting?

**ClickHouse:**
- What is `ReplacingMergeTree`? Why does it exist? (append-only + dedup)
- What does `FINAL` do in a query? (forces dedup at query time)
- What is `issue_datetime` and why is every table ordered by it?
- What is `argMax(price, issue_datetime)`? (get the latest value for each key)
- What is a Projection? (pre-aggregated index stored on disk)
- Why do you NEVER run `UPDATE` or `DELETE` on ClickHouse?

### Key Queries to Write
```sql
-- 1. In DBeaver (MSSQL): show all trades with counterparty name and area
SELECT t.unique_id, cp.name, tc.area_id, tc.quantity, tc.price, tc.start_date, tc.end_date
FROM trade t
JOIN trade_component tc ON tc.trade_id = t.trade_id
JOIN counterparty cp ON cp.counterparty_id = t.counterparty_id

-- 2. In DBeaver (ClickHouse): latest market price per area
SELECT area_id, argMax(price, issue_datetime) AS latest_price
FROM etrm.market_data
GROUP BY area_id

-- 3. In DBeaver (ClickHouse): dedup with FINAL
SELECT * FROM etrm.transaction_exploded FINAL LIMIT 10

-- 4. In DBeaver (ClickHouse): MTM fallback pattern
SELECT trade_id, SUM(COALESCE(realized_pnl, 0) + COALESCE(unrealized_pnl, 0)) AS total_pnl
FROM etrm.transaction_exploded FINAL
GROUP BY trade_id
```

### Exercises
1. Open DBeaver, connect to MSSQL — browse all 7 tables
2. Connect to ClickHouse (port 8123) — browse all 4 tables + 5 views
3. Write and run each of the 4 key queries above
4. Add a new counterparty row to MSSQL manually in DBeaver
5. Query Superset SQL Lab (select ETRM MSSQL) — run the join query there

---

## Layer 3 — Messaging (Kafka)

### What It Is
Kafka is an event queue. Services publish messages to topics. Other services consume them. Nothing is lost — messages are retained on disk for 7 days.

### Why It Exists
When a trade is created, 5 things need to happen: save to MSSQL, explode to ClickHouse, update credit check, notify risk desk, archive to S3. You don't do all 5 synchronously in a REST call — you fire a Kafka event and let each consumer handle its own job independently.

### What to Learn
- What is a topic, producer, consumer, consumer group?
- What is a partition? What is an offset?
- Why does Kafka need Zookeeper (or KRaft in newer versions)?
- What is "at-least-once" delivery? What is idempotency?
- What topics exist in this repo? (`trade.events`, `market.prices`, `settlement.run`, `pnl.calc`)

### Exercises
1. Run `docker exec -it etrm-kafka kafka-topics --list --bootstrap-server localhost:9092`
2. Run a consumer to watch a topic in real time:
   ```bash
   docker exec -it etrm-kafka kafka-console-consumer \
     --bootstrap-server localhost:9092 \
     --topic trade.events --from-beginning
   ```
3. Publish a test message manually:
   ```bash
   docker exec -it etrm-kafka kafka-console-producer \
     --bootstrap-server localhost:9092 --topic trade.events
   ```
4. Read `internal/kafka/` in the Go service — understand producer and consumer code

---

## Layer 4 — Go Service Layer

### What It Is
The Go service is the brain. It:
- Exposes REST APIs (`/trades`, `/pnl`, `/settlement`)
- Consumes Kafka events (trade ingestion, market price updates)
- Writes to both MSSQL and ClickHouse
- Runs business logic (P&L calculation, credit checks, invoice matching)

### Why It Exists
The databases don't know what a "trade" means. The Go service knows the rules: "a STANDARD product delivers every hour", "a FINANCIAL trade doesn't need physical balance", "block this trade if it exceeds credit limit".

### What to Learn

**Go basics (if new to Go):**
- Structs, interfaces, goroutines, channels
- `net/http` or `gin` for REST APIs
- Database connections: `database/sql` for MSSQL, `clickhouse-go` for ClickHouse
- Error handling pattern: always check `err != nil`

**ETRM business logic:**
- **Trade explosion**: how does a trade become 500+ half-hour rows in ClickHouse?
  - STANDARD product for March = 31 days × 48 slots = 1,488 rows
  - CONSTANT product 7am-3pm = 31 days × 16 slots = 496 rows
- **P&L calculation**: `(valuation_price - contracted_price) × quantity`
  - Past slots: realized P&L (use `settle_price`)
  - Future slots: unrealized P&L (use `mtm_price` from curve)
- **Settlement**: after delivery period ends, sum up quantities × prices = invoice amount
- **Invoice matching**: compare our invoice against counterparty's invoice — within tolerance?
- **Credit check**: before accepting a trade, check `SUM(open_notional) < credit_limit`

### Exercises
> **Note:** The Go service is not yet built in this sandbox. These exercises are for when you build it (see IMPLEMENTATION_PLAN.md Day 2). For now, focus on understanding the business logic by studying the seed data and SQL queries.

1. Study `scripts/init_clickhouse.sql` — see how trades are exploded into half-hour intervals (the SQL does what the Go service would do)
2. Run the P&L queries from `docs/clickhouse_queries.md` Pattern 3 — understand the COALESCE fallback
3. Run the credit exposure query from `docs/sql_query_cookbook.md` — understand the credit check logic
4. Trace the full lifecycle manually: pick a trade in MSSQL, find its intervals in ClickHouse, calculate its P&L by hand
5. **Future:** When you build the Go service, implement the trade ingestion → explosion → P&L pipeline

---

## Layer 5 — Monitoring (Grafana + Prometheus)

### What It Is
Prometheus scrapes metrics from all services every 15 seconds. Grafana visualises them on dashboards. This is **ops monitoring** — is the system healthy? Is Kafka lagging? Are queries slow?

### Why It Exists
In production, something is always broken at 3am. Grafana alerts wake the on-call engineer before the traders arrive at 8am.

### What to Learn
- What is a Prometheus metric? (Counter, Gauge, Histogram, Summary)
- What is a scrape endpoint? (Go service exposes `/metrics`)
- What is PromQL? (Prometheus query language)
- What is a Grafana datasource vs a dashboard vs a panel?
- How are Grafana datasources provisioned? (read `infra/grafana/provisioning/`)

### Exercises
See **Lab 6 — Grafana & Prometheus Monitoring** (`docs/labs/lab6_monitoring.md`) for the full hands-on walkthrough.
1. Open Grafana at `http://localhost:3000` (admin/admin)
2. Open Prometheus at `http://localhost:9090` — run `up` to see what's being scraped
3. In Prometheus, run: `ClickHouseProfileEvents_Query` — see ClickHouse activity
4. Build a dashboard with panels from Prometheus + ClickHouse + MSSQL
5. Set up a Grafana alert rule with a threshold and duration

---

## Layer 6 — Business Reporting (Superset / Power BI)

### What It Is
Superset and Power BI are for business users — traders, risk managers, finance. They ask questions like "what is my book exposure this month?" or "how much do we owe counterparty X?". These are not ops questions — they're business questions.

### Why Two BI Tools?
- **Grafana** = ops/telemetry. Real-time metrics. Prometheus + time-series. Think "is the system running?"
- **Superset** = ad-hoc SQL + dashboards. Business data. Think "what is my P&L?"
- **Power BI** = same as Superset but the firm standard. Familiar to non-technical users. Connects natively to MSSQL without any API layer.

### What We Built This Session
| Item | Location |
|---|---|
| 5 ClickHouse views | `etrm.vw_pnl_by_trade`, `vw_pnl_daily`, `vw_market_prices_latest`, `vw_mtm_curve_latest`, `vw_trade_intervals_flat` |
| Superset container | `docker-compose.yml` → port 8088 |
| Market Data dashboard | `http://localhost:8088/superset/dashboard/1/` |
| Trade Book dashboard | `http://localhost:8088/superset/dashboard/2/` |
| Dashboard rebuild script | `scripts/superset_rebuild_dashboards.py` |
| Power BI setup guide | `docs/powerbi_setup.md` |

### What to Learn in Superset
1. **SQL Lab** (top menu) — run queries against MSSQL and ClickHouse directly
2. **Datasets** — a dataset is a table or view that Superset queries. See Settings → Datasets.
3. **Charts** — built from datasets. Pick a viz type, choose columns, configure aggregations.
4. **Dashboards** — collections of charts. Can add filters that apply to all charts.
5. **Filters** — add a date range filter on the Market Data dashboard, link it to the price chart

### What to Learn for Power BI (when VM is ready)
1. **Get Data** → SQL Server → `host.docker.internal:1433` → etrm database
2. **Power Query Editor** — transform data before loading (filter columns, rename, merge)
3. **Data Model** — create relationships between tables (trade → trade_component → counterparty)
4. **DAX measures** — calculated columns and measures. Start with:
   ```
   Total Notional = SUMX(trade_component, trade_component[quantity] * trade_component[price])
   Trade Count = COUNTROWS(trade)
   Avg Price = AVERAGE(trade_component[price])
   ```
5. **Visuals** — bar chart, line chart, matrix table, card (KPI tile), slicers (filters)
6. **Publish** — publish to Power BI Service so it's browser-accessible

### Exercises
1. In Superset SQL Lab: write a query that shows total MW traded per counterparty
2. In Superset: create a new chart — "Trades over time" as a line chart (use `trade.created_at`)
3. In Superset: add that chart to the Trade Book dashboard
4. When VM is ready: connect Power BI to MSSQL, build the same Trade Book dashboard
5. In Power BI: create a DAX measure for `Total Notional` and display it as a card

---

## Suggested Weekly Plan

### Week 1 — Get Comfortable With What's Running
- [ ] Read `docker-compose.yml` end to end — understand every service
- [ ] **Lab 1** — Databases: connect DBeaver, run queries, understand MSSQL vs ClickHouse
- [ ] Read `docs/etrm_concepts.md` — understand the trading domain
- [ ] Explore Superset: SQL Lab, both dashboards, chart builder
- [ ] Run `make help` — understand every Makefile command

### Week 2 — Messaging + Reporting
- [ ] **Lab 2** — Kafka: topics, consumer lag, publish/consume messages
- [ ] **Lab 3** — Superset: build a business report from scratch
- [ ] Read `docs/kafka_guide.md` and `docs/clickhouse_queries.md` cover to cover
- [ ] Read `docs/sql_query_cookbook.md` — run every query, understand the results

### Week 3 — Infrastructure + Monitoring
- [ ] **Lab 5** — Terraform: provision S3, modify config, understand IaC
- [ ] **Lab 6** — Grafana & Prometheus: build dashboards, set up alerts
- [ ] **Lab 8** — Networking: VPC concepts, subnet design, security groups
- [ ] Study `init_clickhouse.sql` — understand why `ReplacingMergeTree` over `MergeTree`

### Week 4 — CI/CD + P&L Investigation
- [ ] **Lab 7** — GitHub Actions: build a CI pipeline, break it, fix it
- [ ] **Lab 4** — P&L Investigation: simulate a real trader query
- [ ] Trace the full trade lifecycle manually: MSSQL trade → ClickHouse intervals → P&L → invoice
- [ ] Research: what is VaR? How would you calculate it from `transaction_exploded`?

### Week 5 — Power BI + Advanced Topics (optional)
- [ ] Follow `docs/powerbi_setup.md` if you have a Windows VM — connect to MSSQL
- [ ] Build a Trade Blotter report in Power BI with DAX measures (see `docs/powerbi_dax_measures.md`)
- [ ] Research: what is a PPA (Power Purchase Agreement)? See `ppa_production` table
- [ ] Research: APAC market specifics — Australian NEM dispatch, JEPX bidding, NZEM hydro

---

## Questions to Be Able to Answer

These are the kinds of questions you'd get in an interview or on the job:

**Database:**
- Why do we use two databases? Why not just MSSQL for everything?
- What happens if you forget `FINAL` on a ClickHouse query?
- What is `issue_datetime` and why does every ClickHouse table have it?
- How do you get the "latest" market price for a given datetime in ClickHouse?

**Trading domain:**
- What is the difference between realized and unrealized P&L?
- What is mark-to-market (MTM)?
- What is a STANDARD vs CONSTANT vs VARIABLE product?
- What happens if a PHYSICAL trade is unbalanced?
- What is invoice matching and why does it need a tolerance?

**Infrastructure:**
- How does the Superset container reach the MSSQL container by hostname?
- What is a Docker health check and why do we need them?
- What would happen if ClickHouse ran out of disk space?
- What does Kafka retain messages for, and what happens after that?

**BI / Reporting:**
- What is the difference between Grafana and Superset?
- When would a trader use Power BI instead of querying SQL directly?
- What is a flat/denormalized view and why do we create them for BI tools?
- What is DirectQuery mode in Power BI vs Import mode?

# Lab 6 — Grafana & Prometheus: Monitoring and Alerting

**Prereqs:** Labs 1-2 complete. Docker stack running. ClickHouse and MSSQL initialised with data.
**Time:** 45-60 minutes
**Goal:** Understand metrics collection, build operational dashboards, set up alerts.

---

## Why This Matters

In production, something breaks at 3am. The trading system processes thousands of trades worth millions of dollars. If ClickHouse is slow, P&L numbers are stale. If Kafka lag grows, market prices are delayed. If MSSQL is down, no trades can be booked.

Prometheus scrapes metrics every 15 seconds. Grafana visualises them. Alerts wake the on-call engineer before traders arrive at 8am. This is your safety net.

---

## Part A — Explore Prometheus (10 min)

### Task A1: Check what's being scraped
Open Prometheus at `http://localhost:9090`

Go to **Status → Targets**. You'll see which services Prometheus is scraping.

**Questions:**
- Which targets are UP and which are DOWN?
- The `trade-service` target is expected to be DOWN (it's not built yet) — that's fine.
- The `clickhouse` target should be UP.

### Task A2: Run your first PromQL query
Go to the **Graph** tab and run:

```promql
up
```

This returns `1` for healthy targets and `0` for unreachable ones.

### Task A3: Query ClickHouse metrics
ClickHouse exposes metrics at its HTTP endpoint. Try these:

```promql
# Total queries executed by ClickHouse
ClickHouseProfileEvents_Query
```

```promql
# Memory usage
ClickHouseMetrics_MemoryTracking
```

```promql
# Number of active connections
ClickHouseMetrics_TCPConnection
```

**Tip:** Start typing `ClickHouse` in the query box — Prometheus autocompletes available metrics.

### Task A4: Understand metric types
| Type | Example | What It Means |
|------|---------|---------------|
| **Counter** | `ClickHouseProfileEvents_Query` | Only goes up. Total queries since restart. |
| **Gauge** | `ClickHouseMetrics_MemoryTracking` | Goes up and down. Current memory usage. |
| **Histogram** | `prometheus_http_request_duration_seconds_bucket` | Distribution of values. |

**Question:** Why would you use `rate()` on a Counter but not on a Gauge? (Answer: Counters only go up, so `rate()` gives you "per second" increase. Gauges already represent a current value.)

---

## Part B — Build Grafana Dashboards (20 min)

Open Grafana at `http://localhost:3000` (admin/admin)

### Task B1: Verify datasources
Go to **Connections → Data sources**. You should see:
- **Prometheus** — `http://prometheus:9090`
- **ClickHouse** — `http://clickhouse:8123`
- **MSSQL** — `mssql:1433`

If any are missing, they should auto-provision from `infra/grafana/provisioning/datasources/datasources.yml`.

### Task B2: Create a System Health dashboard

1. **Dashboards → New → New Dashboard → Add visualization**
2. Select **Prometheus** as the data source

**Panel 1 — Service Health (Stat panel):**
- Query: `up`
- Panel type: **Stat**
- Title: "Service Health"
- Value mappings: 1 = "UP" (green), 0 = "DOWN" (red)

**Panel 2 — ClickHouse Memory (Time series):**
- Query: `ClickHouseMetrics_MemoryTracking`
- Panel type: **Time series**
- Title: "ClickHouse Memory Usage"
- Unit: bytes

**Panel 3 — ClickHouse Queries/sec (Time series):**
- Query: `rate(ClickHouseProfileEvents_Query[5m])`
- Title: "ClickHouse Queries per Second"
- Note: `rate()` converts a counter to a per-second rate over a 5-minute window

Save the dashboard as "System Health".

### Task B3: Create a Business Data dashboard (using ClickHouse SQL)

1. **Add visualization** → select **ClickHouse** as the data source
2. Switch to **SQL Editor** mode (toggle at top of query editor)

**Panel 4 — P&L by Trade (Bar chart):**
```sql
SELECT
    unique_id AS trade_ref,
    sum(coalesce(realized_pnl, 0)) AS realized,
    sum(coalesce(unrealized_pnl, 0)) AS unrealized
FROM etrm.transaction_exploded FINAL
GROUP BY trade_id, unique_id
ORDER BY trade_id
```
- Panel type: **Bar chart**
- Title: "P&L by Trade (Realized vs Unrealized)"

**Panel 5 — Market Prices Over Time (Time series):**
```sql
SELECT
    $__timeInterval(value_datetime) AS time,
    area_id,
    avg(price) AS avg_price
FROM etrm.market_data
WHERE $__timeFilter(value_datetime)
GROUP BY time, area_id
ORDER BY time
```
- Panel type: **Time series**
- Title: "Market Prices by Area"
- Override series names: area_id 1=JEPX, 2=NEM, 3=NZEM (use field override in panel options)

**Panel 6 — Trade Count (MSSQL Stat panel):**
- Data source: **MSSQL**
```sql
SELECT COUNT(*) AS active_trades FROM trade WHERE is_active = 1
```
- Panel type: **Stat**
- Title: "Active Trades"

Save the dashboard as "ETRM Overview".

### Task B4: Arrange the layout
Suggested layout:
```
[ Service Health (stat) ] [ Active Trades (stat) ] [ CH Memory (timeseries) ]
[ P&L by Trade (bar chart - full width)                                     ]
[ Market Prices (timeseries) ] [ CH Queries/sec (timeseries)                ]
```

Drag panels to rearrange. Resize by dragging corners.

---

## Part C — Set Up Alerts (10 min)

### Task C1: Create a ClickHouse memory alert

1. Open the "ClickHouse Memory Usage" panel → **Edit**
2. Go to the **Alert** tab → **Create alert rule**
3. Configure:
   - Condition: `WHEN last() OF query IS ABOVE 1000000000` (1 GB)
   - Evaluate every: `1m`
   - For: `5m` (must be above threshold for 5 minutes)
4. Add notification message: "ClickHouse memory usage exceeds 1GB — investigate slow queries or large result sets"
5. Save

### Task C2: Create a service-down alert
1. **Alerting → Alert rules → New alert rule**
2. Data source: Prometheus
3. Query: `up{job="clickhouse"}`
4. Condition: `WHEN last() IS BELOW 1`
5. For: `2m`
6. Message: "ClickHouse is unreachable — check container health: `docker compose logs clickhouse`"
7. Save

### Task C3: Test the alert (optional)
Stop ClickHouse to trigger the alert:
```bash
docker compose stop clickhouse
```

Wait 2 minutes, check **Alerting → Alert rules** in Grafana. The service-down alert should fire.

Restart it:
```bash
docker compose start clickhouse
```

---

## Part D — Understand What Ops Monitors on the Job (5 min)

On a real trading desk, the ops dashboard shows:

| Panel | Data Source | Why It Matters |
|-------|-----------|----------------|
| Kafka consumer lag | Prometheus (Kafka JMX) | Lag > 0 means market prices are delayed |
| ClickHouse query latency p99 | Prometheus (CH metrics) | Slow queries = stale P&L dashboard |
| MSSQL connection count | Prometheus (MSSQL exporter) | Near limit = trades can't be booked |
| Trade ingestion rate | Prometheus (Go service) | Drop to 0 = service is down |
| Error rate by endpoint | Prometheus (Go service) | Spike = something broke |
| Disk usage (ClickHouse) | Node exporter | Full disk = ClickHouse stops accepting writes |

**Question:** A trader complains that P&L numbers haven't updated in 20 minutes. What panels do you check first?
(Answer: Kafka consumer lag, then ClickHouse query latency, then Go service error rate. The most likely cause is Kafka lag — market prices aren't flowing, so P&L can't recalculate.)

---

## Checkpoint: What You Should Be Able to Do

- [ ] Open Prometheus, check targets, run PromQL queries
- [ ] Explain the difference between Counter, Gauge, and Histogram metrics
- [ ] Create a Grafana dashboard with panels from Prometheus, ClickHouse, and MSSQL
- [ ] Use `rate()` on a counter to get a per-second rate
- [ ] Set up a Grafana alert rule with a threshold and duration
- [ ] Explain what an ops engineer monitors for a trading platform and why

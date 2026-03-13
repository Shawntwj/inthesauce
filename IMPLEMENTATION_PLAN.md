# ETRM + MDM Sandbox - 3-Day Implementation Plan

## Project Overview

A local sandbox that replicates a production Energy Trading & Risk Management (ETRM) stack with a Master Data Management (MDM) extension. It runs ClickHouse + MSSQL + MDM Postgres databases with realistic energy trading data, a Kafka event pipeline, a Go service layer that handles trade lifecycle (P&L, MTM, settlement), an MDM service for counterparty golden records with match/merge and stewardship, Terraform-managed AWS-like infra (LocalStack), monitoring via Prometheus/Grafana, CI/CD via GitHub Actions, and a Power BI-compatible dashboard. The goal is to give you hands-on muscle memory with the exact tools and workflows you'll use on the job.

---

## Technology Stack

### Databases
- **ClickHouse** (clickhouse/clickhouse-server:24.3) - Append-only analytics DB for market data, MTM curves, trade explosions
- **MSSQL** (mcr.microsoft.com/azure-sql-edge:latest) - Transactional DB for trades, components, invoices (counterparty moved to MDM)
- **MDM Postgres** (postgres:16-alpine) - Master Data Management DB for counterparty golden records, incoming records, stewardship queue
- **Redis** (redis:7-alpine) - Cache for live position snapshots + counterparty data from MDM via Kafka

### Message Broker
- **Kafka** (confluentinc/cp-kafka:7.6.0) + **Zookeeper** (confluentinc/cp-zookeeper:7.6.0) - Event streaming for trade events, market data ingestion, counterparty updates
- **Kafka Connect** - Connectors for DB sync (ClickHouse <-> MSSQL)

### Cloud Infra
- **Terraform** + **LocalStack** (localstack/localstack:latest) - Fake AWS (S3, EC2 metadata, VPC) locally; real AWS optional Day 3+
- **AWS Services Mocked**: S3 (payload storage), VPC (network segmentation demo)

### Monitoring
- **Prometheus** (prom/prometheus:latest) - Metrics collection
- **Grafana** (grafana/grafana:latest) - Dashboards, alerts, ClickHouse query monitoring

### CI/CD
- **GitHub Actions** - Scan, build, push, deploy pipeline
- **ArgoCD** 🟡 MOCK - Stubbed as a deployment target in CI config; not running locally

### Security
- **Microsoft Entra ID** 🟡 MOCK - Stubbed with local JWT auth that mimics Entra token structure
- **Zscaler** 🟡 MOCK - Network policies simulated via Docker network isolation

### BI / Dashboard
- **Grafana** (port 3000) - Telemetry & ops dashboards (Prometheus metrics, Kafka lag, system health)
- **Apache Superset** (port 8088) - Business reporting dashboards (trades, P&L, market data, invoices). Runs in Docker, connects to both MSSQL and ClickHouse. Login: `admin` / `admin`
- **Power BI Desktop** 🟡 VM ONLY - Requires Windows VM (VMware Fusion + Windows 11 ARM). Connects to MSSQL via `host.docker.internal:1433`. See `docs/powerbi_setup.md` for setup guide.
- **DBeaver** - Free DB GUI for ad-hoc queries. Connect to MSSQL (`localhost:1433`, user `sa`, pass from `.env`) or ClickHouse (`localhost:8123`)

### Trading / ETRM Layer
- **Go** - Service layer (trade ingestion, P&L calculation, MTM valuation, settlement)
- **Rust** 🟡 MOCK - Noted as used in prod; sandbox uses Go stubs with same interfaces

### MDM Layer
- **Go** - MDM service (counterparty CRUD, ingest, match/merge engine, stewardship queue)
- **MDM Postgres** - Golden records, incoming records, stewardship conflicts
- **Kafka** - Publishes `counterparty.updated` events consumed by ETRM for Redis cache

---

## System Architecture

```
┌─────────────────────────────────┐  ┌──────────────────────────────────┐
│   GRAFANA (port 3000)           │  │   SUPERSET (port 8088)           │
│   Telemetry & ops dashboards    │  │   Business reporting dashboards  │
│   Prometheus metrics, Kafka lag │  │   Trades | P&L | Market Data     │
│   MDM stewardship dashboard     │  │                                  │
└───────────────┬─────────────────┘  └──────────────┬───────────────────┘
                │ HTTP / SQL queries (MSSQL + ClickHouse + MDM Postgres)
┌───────────────▼──────────────────────────────────────────────────────┐
│                      GO TRADE SERVICE (port 8080)                     │
│  - REST API: /trades, /positions, /pnl, /settlement                  │
│  - Trade ingestion (Kafka consumer)                                  │
│  - P&L engine (realized + unrealized)                                │
│  - MTM valuation (mark-to-market / mark-to-model)                   │
│  - Settlement & invoice matching                                     │
│  - Credit check → calls MDM API for counterparty limits              │
│  - Kafka consumer: counterparty.updated → Redis cache                │
└──┬──────────────┬──────────────────┬─────────────────────────────────┘
   │              │                  │
   ▼              ▼                  ▼
┌──────────┐ ┌──────────────┐ ┌────────────────────┐
│  MSSQL   │ │  ClickHouse  │ │  Kafka (9092)      │
│ (1433)   │ │  (8123/9000) │ │  Topics:           │
│          │ │              │ │  - trade.events    │
│ Tables:  │ │ Tables:      │ │  - market.prices   │
│ - trade  │ │ - market_data│ │  - settlement.run  │
│ - comp.  │ │ - mtm_curve  │ │  - pnl.calc        │
│ - invoice│ │ - trade_expl │ │  - counterparty.   │
│          │ │ - ppa_prod   │ │      updated       │
└──────────┘ └──────────────┘ └──────┬─────────────┘
   │              │                  │
   ▼              ▼                  ▼
┌──────────────────────────────┐ ┌─────────────────────────────────────┐
│    S3 (LocalStack:4566)      │ │   MDM SERVICE (port 8081)           │
│    Payload storage, curves,  │ │   - REST API: /counterparties       │
│    audit logs                │ │   - Ingest + match/merge engine     │
│                              │ │   - Stewardship queue               │
│                              │ │   - Publishes counterparty.updated  │
└──────────────────────────────┘ └──────────────┬──────────────────────┘
                                                │
                                                ▼
                                 ┌─────────────────────────────┐
                                 │  MDM POSTGRES (port 5432)    │
                                 │  - golden_record             │
                                 │  - incoming_record           │
                                 │  - stewardship_queue         │
                                 └─────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│  PROMETHEUS (9090) ──────────► GRAFANA (3000)                        │
│  Scrapes: Go trade service, MDM service, ClickHouse, Kafka           │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Database Schema

### MSSQL — Transactional (Source of Truth)

> Counterparty data has been moved to MDM Postgres. The trade table references MDM via `counterparty_mdm_id`.

#### `trade`
```sql
CREATE TABLE trade (
    trade_id            INT IDENTITY PRIMARY KEY,
    unique_id           VARCHAR(50) UNIQUE NOT NULL,     -- business key
    total_quantity      DECIMAL(18,4),
    trade_at_utc        DATETIME2 NOT NULL,
    is_active           BIT DEFAULT 1,
    is_hypothetical     BIT DEFAULT 0,
    counterparty_mdm_id VARCHAR(50) NOT NULL,            -- references MDM golden_record.mdm_id
    broker_id           INT,
    clearer_id          INT,
    trader_id           INT NOT NULL,
    initiator_id        INT,
    source_id           INT,
    invoice_spec_id     INT,
    book_id             INT NOT NULL,
    perspective_id      INT,
    cascade_spec_id     INT,
    created_at          DATETIME2 DEFAULT GETUTCDATE(),
    updated_at          DATETIME2 DEFAULT GETUTCDATE()
);
```

#### `trade_component`
```sql
CREATE TABLE trade_component (
    component_id        INT IDENTITY PRIMARY KEY,
    trade_id            INT NOT NULL REFERENCES trade(trade_id),
    area_id             INT NOT NULL,                    -- market area (NEM, JEPX, NZEM)
    delivery_profile_id INT NOT NULL,                    -- links to delivery schedule
    settlement_mode     VARCHAR(20) NOT NULL,            -- 'PHYSICAL' or 'FINANCIAL'
    price_denominator   VARCHAR(10) NOT NULL,            -- 'JPY', 'AUD', 'NZD', 'USD'
    commodity_type      VARCHAR(20) DEFAULT 'POWER',
    product_type        VARCHAR(20) NOT NULL,            -- 'STANDARD', 'CONSTANT', 'VARIABLE'
    quantity            DECIMAL(18,4) NOT NULL,           -- MW
    price               DECIMAL(18,6) NOT NULL,           -- per MWh
    start_date          DATE NOT NULL,
    end_date            DATE NOT NULL,
    created_at          DATETIME2 DEFAULT GETUTCDATE()
);
```

#### `delivery_profile`
```sql
CREATE TABLE delivery_profile (
    delivery_profile_id INT IDENTITY PRIMARY KEY,
    profile_name        VARCHAR(100),
    interval_minutes    INT NOT NULL DEFAULT 30,          -- 30-min for JEPX, 30-min for NEM
    start_time          TIME,                             -- e.g. 07:00 for CONSTANT products
    end_time            TIME,                             -- e.g. 15:00
    includes_weekends   BIT DEFAULT 0,
    includes_holidays   BIT DEFAULT 0
);
```

#### ~~`counterparty`~~ → Moved to MDM Postgres

> The counterparty table no longer exists in MSSQL. See **MDM Postgres** section below for the `golden_record` table.

#### `invoice`
```sql
CREATE TABLE invoice (
    invoice_id          INT IDENTITY PRIMARY KEY,
    trade_id            INT NOT NULL REFERENCES trade(trade_id),
    component_id        INT REFERENCES trade_component(component_id),
    invoice_number      VARCHAR(50) UNIQUE,
    amount              DECIMAL(18,2) NOT NULL,
    currency            VARCHAR(10) NOT NULL,
    invoice_date        DATE NOT NULL,
    due_date            DATE NOT NULL,
    status              VARCHAR(20) DEFAULT 'PENDING',   -- PENDING, MATCHED, ERROR
    matched_amount      DECIMAL(18,2),
    match_status        VARCHAR(20),                     -- FULL, PARTIAL, MISMATCH
    created_at          DATETIME2 DEFAULT GETUTCDATE()
);
```

#### `curve` (MTM reference data)
```sql
CREATE TABLE curve (
    curve_id            INT IDENTITY PRIMARY KEY,
    curve_name          VARCHAR(100) NOT NULL,
    curve_type          VARCHAR(20) NOT NULL,            -- 'MTM', 'MODEL', 'SETTLE'
    area_id             INT NOT NULL,
    source              VARCHAR(50),                     -- 'EXCHANGE', 'IN_HOUSE'
    is_active           BIT DEFAULT 1
);
```

### MDM Postgres — Counterparty Golden Records

> Counterparty data lives here. The ETRM trade service fetches counterparty/credit data from the MDM service API.

#### `golden_record`
```sql
CREATE TABLE golden_record (
    mdm_id              VARCHAR(50) PRIMARY KEY,    -- e.g. 'MDM-001' — the canonical ID
    canonical_name      VARCHAR(200) NOT NULL,
    short_code          VARCHAR(20) UNIQUE,
    credit_limit        DECIMAL(18,2),
    collateral_amount   DECIMAL(18,2) DEFAULT 0,
    currency            VARCHAR(10) DEFAULT 'JPY',
    is_active           BOOLEAN DEFAULT TRUE,
    data_steward        VARCHAR(100),               -- who owns this record
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    updated_at          TIMESTAMPTZ DEFAULT NOW()
);
```

#### `incoming_record`
```sql
CREATE TABLE incoming_record (
    record_id           SERIAL PRIMARY KEY,
    source_system       VARCHAR(50) NOT NULL,       -- 'TRADING_DESK', 'BROKER_FEED', 'INVOICE_SYSTEM'
    source_id           VARCHAR(50) NOT NULL,
    raw_name            VARCHAR(200) NOT NULL,
    credit_limit        DECIMAL(18,2),
    received_at         TIMESTAMPTZ DEFAULT NOW(),
    match_status        VARCHAR(20) DEFAULT 'PENDING', -- PENDING, AUTO_MERGED, QUEUED, NEW
    matched_mdm_id      VARCHAR(50) REFERENCES golden_record(mdm_id),
    match_score         DECIMAL(5,2)               -- 0-100 confidence
);
```

#### `stewardship_queue`
```sql
CREATE TABLE stewardship_queue (
    queue_id            SERIAL PRIMARY KEY,
    record_a_id         INT REFERENCES incoming_record(record_id),
    record_b_id         INT REFERENCES incoming_record(record_id),
    conflict_fields     JSONB,                      -- e.g. {"credit_limit": [4000000, 5000000]}
    status              VARCHAR(20) DEFAULT 'OPEN', -- OPEN, RESOLVED
    resolved_by         VARCHAR(100),
    resolution          JSONB,                      -- final values the steward picked
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    resolved_at         TIMESTAMPTZ
);
```

### ClickHouse — Analytics (Append-Only)

#### `market_data`
```sql
-- ReplacingMergeTree: deduplicates by issue_datetime
CREATE TABLE market_data (
    value_date          DateTime,
    value_datetime      DateTime,
    issue_datetime      DateTime,          -- when this data point was published
    area_id             UInt32,
    price               Float64,
    volume              Float64,
    source              String,
    currency            String
) ENGINE = ReplacingMergeTree(issue_datetime)
ORDER BY (area_id, value_datetime, issue_datetime);
-- ⚠️ ASSUMED: ReplacingMergeTree with issue_datetime as the version column
-- to handle the "latest value for each value_datetime" pattern from notes
```

#### `mtm_curve`
```sql
CREATE TABLE mtm_curve (
    curve_id            UInt32,
    value_date          Date,
    value_datetime      DateTime,
    issue_datetime      DateTime,
    price               Float64,
    source              String              -- 'MTM' or 'MODEL'
) ENGINE = ReplacingMergeTree(issue_datetime)
ORDER BY (curve_id, value_datetime, issue_datetime);
```

#### `transaction_exploded`
```sql
-- Each trade broken down to half-hour intervals for P&L
CREATE TABLE transaction_exploded (
    trade_id            UInt32,
    component_id        UInt32,
    unique_id           String,
    interval_start      DateTime,           -- half-hour slot start
    interval_end        DateTime,
    quantity            Float64,            -- MW for this slot
    price               Float64,            -- contracted price
    settle_price        Nullable(Float64),  -- actual settlement price (null if future)
    mtm_price           Nullable(Float64),  -- mark-to-market price
    realized_pnl        Nullable(Float64),
    unrealized_pnl      Nullable(Float64),
    area_id             UInt32,
    currency            String,
    issue_datetime      DateTime
) ENGINE = ReplacingMergeTree(issue_datetime)
ORDER BY (trade_id, component_id, interval_start, issue_datetime);
-- Query pattern from notes:
-- SELECT * FROM transaction_exploded FINAL
-- WHERE unique_id = '0000'
-- This gives deduplicated latest values
```

#### `ppa_production`
```sql
CREATE TABLE ppa_production (
    ppa_id              UInt32,
    production_date     Date,
    interval_start      DateTime,
    interval_end        DateTime,
    actual_mwh          Float64,
    forecast_mwh        Float64,
    price               Float64,
    issue_datetime      DateTime
) ENGINE = ReplacingMergeTree(issue_datetime)
ORDER BY (ppa_id, interval_start, issue_datetime);
```

### Helper Table (MSSQL)

#### `half_hour_intervals`
```sql
-- Pre-populated calendar table for left-joining trades
-- Covers 2024-01-01 to 2026-12-31, every 30 minutes
CREATE TABLE half_hour_intervals (
    interval_start      DATETIME2 PRIMARY KEY,
    interval_end        DATETIME2 NOT NULL,
    trade_date          DATE NOT NULL,
    is_weekend          BIT NOT NULL,
    is_holiday          BIT DEFAULT 0
);
-- ⚠️ ASSUMED: Seed script generates these; holidays hardcoded for JEPX/NEM/NZEM
```

---

## Core Features Implementation

### 1. Trade Ingestion Service 🟢 CRITICAL

**File:** `services/trade-service/cmd/ingest/main.go`

```go
// Pseudo-code
func IngestTrade(event TradeEvent) {
    // 1. Validate trade fields (counterparty exists in MDM, area valid)
    //    - Call MDM API: GET /counterparties/{mdm_id} to verify counterparty
    //    - Run credit check against MDM credit limit
    // 2. Insert into MSSQL: trade + trade_component rows (counterparty_mdm_id)
    // 3. Determine product type (STANDARD/CONSTANT/VARIABLE)
    //    - STANDARD: every hour, full day
    //    - CONSTANT: fixed window (e.g. 7am-3pm daily)
    //    - VARIABLE: custom delivery_profile
    // 4. Explode trade into half-hour intervals
    //    -> INSERT into ClickHouse transaction_exploded
    // 5. Publish Kafka event: trade.created
}
```
**⚠️ ASSUMED:** Product type detection is based on delivery_profile fields (start_time, end_time, interval). If all-day = STANDARD, fixed window = CONSTANT, custom = VARIABLE.

### 2. P&L Calculation Engine 🟢 CRITICAL

**File:** `services/trade-service/cmd/pnl/main.go`

```go
// Pseudo-code — runs as cron job or Kafka consumer
func CalculatePnL(tradeID int, asOfDate time.Time) {
    // 1. Get all half-hour slots from transaction_exploded FINAL
    //    WHERE trade_id = tradeID
    // 2. For each slot:
    //    a. If slot is in the past (delivered):
    //       realized_pnl = (settle_price - contracted_price) * quantity
    //    b. If slot is in the future (not yet delivered):
    //       unrealized_pnl = (mtm_price - contracted_price) * quantity
    //       mtm_price = COALESCE(settle_price, mtm_curve_price)
    // 3. Aggregate:
    //    total_realized = SUM(realized_pnl)
    //    total_unrealized = SUM(unrealized_pnl)
    //    total_pnl = total_realized + total_unrealized
    // 4. Write results back to ClickHouse with new issue_datetime
}

// Key query from notes:
// AVG(COALESCE(settleprice.value, mtmprice.value))
// This is the MTM fallback pattern: use settlement price if available,
// otherwise use the curve price
```

### 3. MTM Curve Service 🟡 MOCK (hardcoded curves)

**File:** `services/trade-service/cmd/mtm/main.go`

```go
// Pseudo-code
func GenerateMTMCurve(areaID int, startDate, endDate time.Time) {
    // 🟡 MOCK: In production this uses a quant model based on historicals
    // For sandbox: generate synthetic curve data
    // base_price + random_walk + seasonal_pattern
    //
    // Japanese JEPX: base ~10 JPY/kWh, volatile
    // Australian NEM: base ~80 AUD/MWh, spiky
    // NZ NZEM: base ~60 NZD/MWh, hydro-dependent
    //
    // Insert into ClickHouse mtm_curve with current issue_datetime
}
```

### 4. Market Data Scraper 🟡 MOCK (synthetic data)

**File:** `services/scraper/main.go`

```go
// Pseudo-code
func ScrapeMarketPrices() {
    // 🟡 MOCK: Production scrapes from JEPX, AEMO, Transpower APIs
    // For sandbox: generate realistic synthetic half-hourly prices
    // Publish to Kafka topic: market.prices
    // ClickHouse consumer writes to market_data table
}
```

### 5. Settlement & Invoice Matching 🟢 CRITICAL

**File:** `services/trade-service/cmd/settlement/main.go`

```go
// Pseudo-code
func RunSettlement(tradeID int, period DateRange) {
    // 1. Get delivered half-hours from transaction_exploded FINAL
    // 2. Calculate settlement amount per component:
    //    amount = SUM(quantity * settle_price) for period
    // 3. Generate invoice record in MSSQL
    // 4. Match against counterparty invoices:
    //    - FULL match: amounts equal within tolerance
    //    - PARTIAL: within 5% tolerance
    //    - MISMATCH: flag for manual review
    // 5. Check physical balance: BUY qty must equal SELL qty
    //    (imbalance = deviation charge from grid operator)
}
```

### 6. Credit & Risk Checks

**File:** `services/trade-service/cmd/risk/main.go`

```go
// Pseudo-code
func CheckCreditLimit(counterpartyMDMID string, newTradeValue float64) bool {
    // 1. Get current exposure: SUM of open trade values for counterparty from MSSQL
    // 2. Get credit_limit from MDM API: GET /counterparties/{mdm_id}
    //    (or read from Redis cache populated by counterparty.updated Kafka consumer)
    // 3. Return (current_exposure + newTradeValue) <= credit_limit
}

func CalculateVaR(portfolioID int) float64 {
    // 🟡 MOCK: Hardcoded VaR formula
    // In production: quant team provides formulas, we translate to SQL
    // For sandbox: simple historical VaR = 95th percentile of daily P&L changes
    return hardcodedVaR
}
```

### 7. Monitoring & Alerts

**Files:** `infra/prometheus/prometheus.yml`, `infra/grafana/dashboards/`

Grafana dashboards:
- **Trade Blotter**: live trades from MSSQL
- **P&L Monitor**: realized/unrealized from ClickHouse
- **System Health**: pod status, DB connections, Kafka lag
- **ClickHouse Queries**: slow query log, memory usage
- **Invoice Matching**: error rates, mismatches
- **MDM Stewardship**: golden record count, queue depth, match distribution, recent ingestions

### 8. Terraform / AWS (LocalStack)

**File:** `infra/terraform/main.tf`

```hcl
# ⚠️ ASSUMED: Using LocalStack to simulate AWS locally
# Provisions: S3 buckets, VPC with subnets (demo segmentation)
provider "aws" {
  endpoints {
    s3  = "http://localhost:4566"
    ec2 = "http://localhost:4566"
  }
  # LocalStack config...
}

resource "aws_s3_bucket" "payloads"   { bucket = "etrm-payloads" }
resource "aws_s3_bucket" "curves"     { bucket = "etrm-curves" }
resource "aws_s3_bucket" "audit_logs" { bucket = "etrm-audit" }

# VPC segmentation demo (notes: 10.124.128.0/17 for rainman, 10.125.0.0/27 for power)
resource "aws_vpc" "etrm_vpc" {
  cidr_block = "10.124.128.0/17"
}
resource "aws_subnet" "rainman_subnet" {
  vpc_id     = aws_vpc.etrm_vpc.id
  cidr_block = "10.124.128.0/18"
}
resource "aws_subnet" "power_subnet" {
  vpc_id     = aws_vpc.etrm_vpc.id
  cidr_block = "10.125.0.0/27"
}
```

### 9. CI/CD Pipeline

**File:** `.github/workflows/ci.yml`

```yaml
# Scan -> Build -> Push -> Deploy
# ⚠️ ASSUMED: ArgoCD deploy step is a stub (prints deployment manifest)
name: ETRM CI/CD
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Lint & Test
        run: cd services/trade-service && go test ./...
      - name: Build Docker image
        run: docker build -t etrm-trade-service .
      - name: Push to registry
        run: echo "🟡 MOCK - would push to ECR"
      - name: Deploy via ArgoCD
        run: echo "🟡 MOCK - would trigger ArgoCD sync"
```

---

## 3-Day Sprint Plan

### Day 1: Infrastructure (Get Everything Running)

**Morning (4 hrs):**
- [ ] Create project folder structure (see below)
- [ ] Write `docker-compose.yml` with ALL services: ClickHouse, MSSQL, Kafka+Zookeeper, Redis, Prometheus, Grafana, LocalStack
- [ ] `docker compose up -d` — verify all containers healthy
- [ ] Connect to MSSQL via DBeaver/DataGrip, run DDL for all MSSQL tables
- [ ] Connect to ClickHouse via DBeaver (port 8123), run DDL for all ClickHouse tables

**Afternoon (4 hrs):**
- [ ] Write seed script (`scripts/seed_data.go` or `.sql`):
  - 3 counterparties, 3 delivery profiles (STANDARD/CONSTANT/VARIABLE)
  - 5 sample trades with components across JEPX, NEM, NZEM
  - Populate half_hour_intervals table (2024-2026)
  - Generate 30 days of synthetic market_data in ClickHouse
  - Generate MTM curves in ClickHouse
- [ ] Write Terraform config for LocalStack (S3 buckets, VPC)
- [ ] `terraform init && terraform apply` against LocalStack
- [ ] Set up Prometheus scrape configs + import Grafana dashboard JSON

- [ ] Verify MDM Postgres: `golden_record` table seeded with 3 counterparties
- [ ] Create `counterparty.updated` Kafka topic

**Done criteria:** `docker compose up` brings up everything. Can query all three databases (MSSQL, ClickHouse, MDM Postgres). `golden_record` seeded. `counterparty.updated` topic exists. Grafana shows system metrics. S3 buckets exist in LocalStack.

---

### Day 2: Data + Trading Logic (Core ETRM + MDM)

**Morning (4 hrs):**
- [ ] Bootstrap Go trade service: `services/trade-service/`
  - Kafka consumer for `trade.events` topic
  - Trade ingestion: parse event -> insert MSSQL (with `counterparty_mdm_id`) -> explode to ClickHouse
  - REST endpoints: `GET /trades`, `GET /trades/:id`, `POST /trades`
- [ ] Bootstrap Go MDM service: `services/mdm-service/`
  - REST API: `GET/POST /counterparties`, `GET /counterparties/:mdm_id`, `POST /counterparties/ingest`
  - Stewardship: `GET /stewardship/queue`, `POST /stewardship/queue/:id/resolve`
  - Match/merge engine (score + route: AUTO_MERGE / QUEUE / NEW)
- [ ] Write trade explosion logic (break trade into half-hour intervals)
  - Left join delivery_profile + half_hour_intervals
  - Insert into ClickHouse `transaction_exploded`
- [ ] Test: POST a trade via API, verify it appears in both DBs

**Afternoon (4 hrs):**
- [ ] P&L calculation engine:
  - Query `transaction_exploded FINAL` (ClickHouse dedup pattern)
  - Realized P&L for past intervals, unrealized for future
  - `AVG(COALESCE(settle_price, mtm_price))` pattern
  - REST endpoint: `GET /pnl/:trade_id`
- [ ] Settlement stub:
  - Generate invoice from delivered intervals
  - Basic match logic (exact amount match)
  - REST endpoint: `GET /settlement/:trade_id`
- [ ] Credit check: calls MDM API (`GET /counterparties/:mdm_id`) for credit limit instead of local MSSQL join
- [ ] Kafka producer: synthetic market price generator (cron-like, every 30s publishes prices)
- [ ] MDM Kafka publisher: publish `counterparty.updated` events when golden record changes
- [ ] ETRM Kafka consumer: listen to `counterparty.updated`, cache counterparty data in Redis

**Done criteria:** Can create a trade via API, see it exploded in ClickHouse, get P&L breakdown (realized + unrealized), generate an invoice, see market prices flowing into ClickHouse. MDM ingest with known name returns AUTO_MERGE. Ambiguous name lands in stewardship queue. Credit check calls MDM. `counterparty.updated` events appear in Kafka.

---

### Day 3: Dashboard + Validation (Make It Visible)

**Morning (4 hrs):**
- [ ] Grafana dashboards (import JSON):
  - Trade Blotter (MSSQL datasource): all active trades
  - P&L Monitor (ClickHouse datasource): realized vs unrealized by trade
  - Market Data (ClickHouse): price charts by area (JEPX/NEM/NZEM)
  - Invoice Matching: status breakdown (matched/error/pending)
  - System Health: Kafka consumer lag, DB query times
  - MDM Stewardship (MDM Postgres datasource): golden record count, queue depth, match distribution, recent ingestions
- [ ] Wire Grafana alerts: P&L threshold breach, invoice mismatch, Kafka lag > 1000

**Afternoon (4 hrs):**
- [ ] 🔴 GitHub Actions CI pipeline (build + test + lint)
- [ ] Write ClickHouse query cookbook (`docs/clickhouse_queries.md`):
  - Dedup with FINAL
  - Time-travel query (WHERE issue_datetime < '2023-01-01')
  - Projection example
  - argMax pattern for latest values
- [ ] Run end-to-end scenario:
  1. Ingest 10 trades (mix of PHYSICAL/FINANCIAL, STANDARD/CONSTANT/VARIABLE)
  2. Let market data flow for 5 minutes
  3. Run P&L calc
  4. Run settlement for completed trades
  5. Check Grafana dashboards show everything
  6. Verify credit limits block over-limit trade
- [ ] Run MDM end-to-end scenario:
  1. `POST /counterparties/ingest {"source_system":"BROKER_FEED","raw_name":"TEC","credit_limit":4500000}` → AUTO_MERGE to MDM-001
  2. `POST /counterparties/ingest {"source_system":"INVOICE_SYSTEM","raw_name":"Tokyo Energy","credit_limit":5000000}` → stewardship queue
  3. `POST /stewardship/queue/1/resolve {"credit_limit":4750000}` → golden record updated, Kafka event published
  4. Verify Redis cache reflects new credit limit
  5. POST trade exceeding new limit → rejected
- [ ] Document what you skipped (see section 10)

**Done criteria:** Full end-to-end demo works for both ETRM and MDM flows. Grafana dashboards are populated (including MDM stewardship). CI pipeline runs. You can explain every component to an interviewer.

---

## Project Structure

```
inthesauce/
├── docker-compose.yml              # ALL services
├── .env                            # Environment variables
├── .github/
│   └── workflows/
│       └── ci.yml                  # GitHub Actions pipeline
├── Makefile                        # Convenience commands
│
├── services/
│   ├── trade-service/              # Go service — ETRM core
│   │   ├── Dockerfile
│   │   ├── go.mod
│   │   ├── go.sum
│   │   ├── cmd/
│   │   │   ├── server/main.go      # HTTP server + Kafka consumer
│   │   │   ├── pnl/main.go         # P&L calculation (can be run as cron)
│   │   │   ├── settlement/main.go  # Settlement runner
│   │   │   └── seed/main.go        # Data seeder
│   │   ├── internal/
│   │   │   ├── models/             # Trade, Component structs
│   │   │   ├── handlers/           # HTTP handlers
│   │   │   ├── kafka/              # Kafka producer/consumer (incl. counterparty.updated)
│   │   │   ├── db/                 # MSSQL + ClickHouse connections
│   │   │   ├── pnl/               # P&L engine
│   │   │   ├── settlement/        # Settlement + invoice logic
│   │   │   ├── risk/              # Credit check (calls MDM API), VaR stub
│   │   │   └── exploder/          # Trade -> half-hour explosion
│   │   └── tests/
│   │
│   ├── mdm-service/                # Go service — Master Data Management
│   │   ├── Dockerfile
│   │   ├── go.mod
│   │   ├── cmd/
│   │   │   └── server/main.go      # HTTP server
│   │   ├── internal/
│   │   │   ├── models/
│   │   │   │   └── counterparty.go # GoldenRecord, IncomingRecord structs
│   │   │   ├── handlers/
│   │   │   │   ├── counterparty.go # GET/POST/PUT /counterparties
│   │   │   │   └── stewardship.go  # GET/POST /stewardship/queue
│   │   │   ├── db/
│   │   │   │   └── postgres.go     # Postgres connection
│   │   │   ├── matcher/
│   │   │   │   └── match.go        # Match/merge engine
│   │   │   └── publisher/
│   │   │       └── kafka.go        # Publishes counterparty.updated events
│   │   └── tests/
│   │
│   └── scraper/                    # Market data generator
│       ├── Dockerfile
│       └── main.go                 # Publishes synthetic prices to Kafka
│
├── infra/
│   ├── terraform/
│   │   ├── main.tf                 # LocalStack AWS resources
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── prometheus/
│   │   └── prometheus.yml          # Scrape configs
│   ├── grafana/
│   │   ├── provisioning/
│   │   │   ├── datasources/
│   │   │   │   ├── clickhouse.yml
│   │   │   │   ├── mssql.yml
│   │   │   │   └── prometheus.yml
│   │   │   └── dashboards/
│   │   │       └── dashboard.yml
│   │   └── dashboards/
│   │       ├── trade-blotter.json
│   │       ├── pnl-monitor.json
│   │       ├── market-data.json
│   │       ├── invoice-matching.json
│   │       ├── system-health.json
│   │       └── mdm-stewardship.json  # MDM golden records, queue depth, match distribution
│   ├── superset/
│   │   ├── superset_config.py      # Superset config (secret key, DB URI)
│   │   └── superset_init.sh        # Bootstrap: admin user + DB connections
│   └── clickhouse/
│       └── config.xml              # ClickHouse server config
│
├── scripts/
│   ├── init_mssql.sql              # MSSQL DDL + seed data (no counterparty — moved to MDM)
│   ├── init_clickhouse.sql         # ClickHouse DDL (auto-run on container start)
│   ├── init_mdm_postgres.sql       # MDM Postgres DDL + seed data (golden_record, incoming_record, stewardship_queue)
│   ├── powerbi_views_mssql.sql     # Flat/denormalized views for Power BI / Superset
│   ├── powerbi_views_clickhouse.sql# ClickHouse views for Power BI / Superset
│   └── superset_rebuild_dashboards.py  # Recreates Superset dashboards via API
│
├── docs/
│   ├── clickhouse_queries.md       # Query cookbook
│   ├── etrm_diagram.md             # System explanation
│   ├── network_diagram.md          # VPC/subnet layout
│   ├── powerbi_setup.md            # Power BI Desktop VM setup + connection guide
│   ├── learning_roadmap.md         # How to reverse-engineer this stack to learn it
│   └── labs/
│       ├── lab1_databases.md           # MSSQL + ClickHouse + MDM Postgres
│       ├── lab2_kafka.md               # Topics, consumer lag, produce/consume
│       ├── lab3_superset_reporting.md  # Build business reports
│       ├── lab4_pnl_investigation.md   # Trace a P&L discrepancy end-to-end
│       ├── lab5_terraform.md           # Infrastructure as Code with LocalStack
│       ├── lab6_monitoring.md          # Grafana + Prometheus dashboards & alerts
│       ├── lab7_cicd.md                # GitHub Actions CI pipeline
│       ├── lab8_networking.md          # VPC, subnets, security groups
│       ├── lab9_mdm.md                 # Golden records, match/merge, stewardship
│       ├── lab10_go_trade_service.md   # Build REST API + trade explosion engine
│       ├── lab11_incident_response.md  # Simulate & fix "P&L is wrong" incident
│       ├── lab12_performance_tuning.md # Profile & optimize queries 100x faster
│       ├── lab13_settlement_invoicing.md # Settlement lifecycle & invoice matching
│       ├── lab14_kafka_streaming_pipeline.md # Real-time market data pipeline
│       └── lab15_system_design.md      # Architect a full ETRM (capstone)
│
└── IMPLEMENTATION_PLAN.md          # This file
```

---

## Key Dependencies

### Docker Images (pin these in docker-compose.yml)
```yaml
services:
  clickhouse:
    image: clickhouse/clickhouse-server:24.1
    ports: ["8123:8123", "9000:9000"]

  mssql:
    image: mcr.microsoft.com/mssql/server:2022-latest
    ports: ["1433:1433"]

  zookeeper:
    image: confluentinc/cp-zookeeper:7.6.0
    ports: ["2181:2181"]

  kafka:
    image: confluentinc/cp-kafka:7.6.0
    ports: ["9092:9092"]

  redis:
    image: redis:7-alpine
    ports: ["6379:6379"]

  prometheus:
    image: prom/prometheus:v2.49.0
    ports: ["9090:9090"]

  grafana:
    image: grafana/grafana:10.3.1
    ports: ["3000:3000"]

  localstack:
    image: localstack/localstack:3.1
    ports: ["4566:4566"]

  mdm-postgres:
    image: postgres:16-alpine
    ports: ["5432:5432"]
```

### Go Dependencies
```
github.com/gin-gonic/gin          # HTTP framework
github.com/segmentio/kafka-go     # Kafka client
github.com/denisenkom/go-mssqldb  # MSSQL driver
github.com/ClickHouse/clickhouse-go/v2  # ClickHouse driver
github.com/go-redis/redis/v9      # Redis client
github.com/prometheus/client_golang # Prometheus metrics
github.com/aws/aws-sdk-go-v2      # S3 client (LocalStack)
```

### Terraform
```
hashicorp/aws ~> 5.0
```

---

## Environment Variables (`.env`)

```bash
# ── MSSQL ──
MSSQL_SA_PASSWORD=YourStr0ngPass1
MSSQL_HOST=localhost
MSSQL_PORT=1433
MSSQL_DB=etrm

# ── ClickHouse ──
CLICKHOUSE_HOST=localhost
CLICKHOUSE_HTTP_PORT=8123
CLICKHOUSE_NATIVE_PORT=9000
CLICKHOUSE_DB=etrm
CLICKHOUSE_USER=default
CLICKHOUSE_PASSWORD=

# ── Kafka ──
KAFKA_BROKERS=localhost:9092
KAFKA_TOPIC_TRADES=trade.events
KAFKA_TOPIC_PRICES=market.prices
KAFKA_TOPIC_SETTLEMENT=settlement.run
KAFKA_TOPIC_PNL=pnl.calc
KAFKA_TOPIC_COUNTERPARTY=counterparty.updated
KAFKA_GROUP_ID=etrm-service

# ── Redis ──
REDIS_URL=redis://localhost:6379/0

# ── AWS / LocalStack ──
AWS_ENDPOINT=http://localhost:4566
AWS_REGION=ap-southeast-1
AWS_ACCESS_KEY_ID=test
AWS_SECRET_ACCESS_KEY=test
S3_BUCKET_PAYLOADS=etrm-payloads
S3_BUCKET_CURVES=etrm-curves
S3_BUCKET_AUDIT=etrm-audit

# ── Grafana ──
GF_SECURITY_ADMIN_USER=admin
GF_SECURITY_ADMIN_PASSWORD=admin

# ── Service ──
SERVICE_PORT=8080
LOG_LEVEL=debug

# ── MDM Service ──
MDM_SERVICE_URL=http://localhost:8081
MDM_POSTGRES_URL=postgres://mdm:mdmpass@localhost:5432/mdm

# ── Risk Parameters ──
DEFAULT_CREDIT_LIMIT=2000000
MAX_EXPOSURE_PER_COUNTERPARTY=2000000
VAR_CONFIDENCE_LEVEL=0.95

# ── Market Areas ──
# JEPX=1, NEM=2, NZEM=3 (area_id mapping)
```

---

## What I Am Deliberately Skipping

| Item | Why Skipped | When to Add |
|------|-------------|-------------|
| **Real AWS deployment** | LocalStack is sufficient for learning Terraform; real AWS costs money and takes time | Week 2: deploy to real AWS free tier |
| **EKS / Kubernetes** | 🔴 >2 hours to set up properly; Docker Compose gives same learning | Week 3: minikube or EKS |
| **ArgoCD** | Requires K8s cluster; stubbed in CI pipeline | After EKS is set up |
| **Microsoft Entra ID** | Requires Azure AD tenant; stubbed with local JWT | Week 4: Azure free tier |
| **Zscaler** | Enterprise product, can't self-host; Docker network isolation demonstrates the concept | N/A - learn conceptually |
| **Power BI Desktop** | Requires Windows VM on Mac; Superset is now the local BI layer | Set up VMware Fusion + Windows 11 ARM (see `docs/powerbi_setup.md`) then connect to `host.docker.internal:1433` |
| **Rust services** | Notes mention Rust in prod; Go is faster to prototype same logic | Week 5+: rewrite hot path in Rust |
| **Real market data APIs** | JEPX/AEMO APIs need registration; synthetic data teaches same patterns | Week 2: register for free data feeds |
| **PgBouncer / replication** | Connection pooling & replication are ops concerns, not Day 1 | Week 4: add PgBouncer in front of MSSQL |
| **VaR / scenario analysis** | Needs quant formulas; hardcoded stub is sufficient | When you get the actual formulas from the team |
| **Kafka Connect** | Full connector setup is >1hr; direct Kafka produce/consume teaches the pattern | Week 3: add ClickHouse Kafka engine |
| **Multi-region replication** | Cloud-specific, expensive | After real AWS deployment |
| **Full APAC holiday calendars** | Need accurate per-market data; hardcode a few for now | Populate from public holiday APIs |
| **Mark-to-model (in-house curve)** | Needs quant expertise; MTM from exchange data is sufficient | When domain knowledge improves |
| **Trade audit trail** | S3 write stubs exist; full audit logging is a Day 5 concern | Week 2 |
| **LEI lookup** | Real Legal Entity Identifier validation requires a paid API | When you have access to GLEIF free tier |
| **Full fuzzy matching library** | Levenshtein/Jaro-Winkler adds complexity; simple string match teaches the concept | Week 5+: add `go-text/similarity` |
| **Stewardship UI** | A proper React UI takes a full day; Grafana dashboard + API calls demonstrate the concept | Week 5+: build a simple React form |
| **Multi-entity MDM** | Only counterparty is extracted; market areas and curves stay in ETRM | Week 6+: extract `curve` table too |
| **MDM audit trail** | Change history on golden records is important in production; skipped here | Week 3: add `golden_record_history` table |

---

## Quick Reference: ClickHouse Patterns You Must Know

These come directly from the notes and will be asked about:

```sql
-- 1. DEDUP: Always use FINAL before WHERE on ReplacingMergeTree tables
SELECT * FROM transaction_exploded FINAL
WHERE unique_id = '0000';

-- 2. LATEST VALUE: Get most recent data for each value_datetime
SELECT
    value_datetime,
    argMax(price, issue_datetime) AS latest_price
FROM market_data
WHERE area_id = 1
GROUP BY value_datetime;

-- 3. TIME TRAVEL: See what data looked like at a past point in time
SELECT * FROM market_data FINAL
WHERE issue_datetime < '2023-11-01 00:00:00'
  AND area_id = 1;

-- 4. MTM FALLBACK: Use settlement price if available, else MTM curve
SELECT
    t.interval_start,
    t.quantity,
    t.price AS contracted_price,
    AVG(COALESCE(t.settle_price, t.mtm_price)) AS valuation_price,
    t.quantity * (AVG(COALESCE(t.settle_price, t.mtm_price)) - t.price) AS pnl
FROM transaction_exploded FINAL t
WHERE t.trade_id = 123
GROUP BY t.interval_start, t.quantity, t.price;

-- 5. WHY NO MUTATIONS: ClickHouse is append-only. Never UPDATE/DELETE.
--    Instead, insert new row with updated issue_datetime.
--    ReplacingMergeTree handles dedup at query time (FINAL) or merge time.

-- 6. PROJECTIONS: Pre-aggregated index stored as a secondary table on disk
ALTER TABLE market_data ADD PROJECTION daily_avg (
    SELECT area_id, toDate(value_datetime) AS d, avg(price)
    GROUP BY area_id, d
);
```

---

## Quick Reference: ETRM Domain Cheat Sheet

Only what you need to write the code:

| Concept | What It Means For Your Code |
|---------|----------------------------|
| **Trade** | A contract. Has 1+ components. Source of truth in MSSQL. |
| **Component** | A product within a trade. Defines what/when/how much power is delivered. |
| **STANDARD product** | Deliver every hour for a period (e.g., all of March). Already-known profile. |
| **CONSTANT product** | Deliver during a fixed daily window (e.g., 7am-3pm). |
| **VARIABLE product** | Custom delivery schedule. Uses delivery_profile to define slots. |
| **PHYSICAL settlement** | Actual power delivery. BUY must equal SELL (imbalance = penalty). |
| **FINANCIAL settlement** | Cash-settled bet. No physical delivery. Buy/sell don't need to balance. |
| **MTM (Mark-to-Market)** | Current valuation of a future trade using market curve prices. |
| **Realized P&L** | Profit/loss on delivered intervals (past). `(settle_price - contract_price) * qty` |
| **Unrealized P&L** | Estimated P/L on future intervals. `(mtm_price - contract_price) * qty` |
| **Half-hour interval** | The atomic time unit. Every trade is exploded into 30-min slots. |
| **issue_datetime** | When a data point was recorded. Key for dedup and time-travel in ClickHouse. |
| **Imbalance** | Physical trades must net to zero. Grid operator charges fee for deviation. |
| **Credit limit** | Max exposure per counterparty. Now managed by MDM, fetched via API or Redis cache. |
| **Golden record** | The canonical, deduplicated counterparty record in MDM. One per real-world entity. |
| **Incoming record** | A raw counterparty record from a source system. Gets matched/merged into a golden record. |
| **Match/merge** | MDM engine that scores how well an incoming record matches existing golden records. Auto-merge if high confidence, queue for stewardship if ambiguous. |
| **Stewardship** | Human review of conflicts the match engine couldn't auto-resolve (e.g., conflicting credit limits from two sources). |
| **counterparty_mdm_id** | The FK in MSSQL `trade` table that references MDM's `golden_record.mdm_id`. Replaced the old `counterparty_id INT`. |

# Master Guide — ETRM + MDM Sandbox 3-Day Sprint

Build first, understand later. This guide is optimised for one developer with 3 days.

The ETRM sandbox now includes a **Master Data Management (MDM)** extension. The `counterparty` table has been extracted from MSSQL into a dedicated MDM service with its own Postgres database, match/merge engine, and stewardship queue. The ETRM consumes counterparty data from MDM instead of owning it directly.

**Priority key:**
- 🟢 CRITICAL — must-have, blocks everything else
- 🟡 MOCK — fake it for now, wire in properly later
- 🔴 SLOW — takes >2 hours, schedule carefully
- ⚠️ ASSUMED — ambiguous domain area, simplest option chosen

---

## Before You Start

### Prerequisites
| Tool | Install Command | What It's For |
|------|----------------|---------------|
| Docker Desktop | [docker.com](https://www.docker.com/products/docker-desktop/) | Runs all services |
| DBeaver | `brew install --cask dbeaver-community` | SQL client for MSSQL + ClickHouse + MDM Postgres |
| Terraform | `brew install terraform` | Infrastructure as Code |
| AWS CLI | `brew install awscli` | Interact with S3 (LocalStack) |
| Git | pre-installed on macOS | Version control |

### Key URLs
| Service | URL | Credentials |
|---------|-----|-------------|
| Superset | http://localhost:8088 | admin / admin |
| Grafana | http://localhost:3000 | admin / admin |
| Prometheus | http://localhost:9090 | none |
| ClickHouse HTTP | http://localhost:8123 | default / (blank) |
| MSSQL | localhost:1433 | sa / YourStr0ngPass1 |
| MDM Service | http://localhost:8081 | none |
| MDM Postgres | localhost:5432 | mdm / mdmpass |
| LocalStack | http://localhost:4566 | test / test |

---

## Architecture Overview

```
BROKER FEED  ──► POST /counterparties/ingest
INVOICE SYS  ──►        │
                   MDM SERVICE (port 8081)
                         │
                   match/merge engine
                   score >= 90 → AUTO_MERGE
                   score 60-89 → stewardship queue (human resolves)
                   score < 60  → new golden record
                         │
                   MDM Postgres (port 5432)
                   golden_record | incoming_record | stewardship_queue
                         │
                   Kafka: counterparty.updated
                         │
              ┌──────────┴──────────┐
              ▼                     ▼
        ETRM Redis cache      (future systems)
        (trade-service reads   risk system,
         credit limit here)    invoicing, etc.

              │
              ▼
┌──────────────────────────────────────────────────────────┐
│   ETRM TRADE SERVICE (port 8080)                         │
│   /trades, /pnl, /settlement                             │
│   Credit check calls MDM for counterparty limits         │
└──┬──────────────┬──────────────────┬─────────────────────┘
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
└──────────┘ └──────────────┘ └────────────────────┘
```

The ETRM no longer owns counterparty data. It reads from cache, cache is populated by Kafka, Kafka is driven by MDM.

---

## What Changed vs What Stayed (MDM Pivot)

| Component | Change? | What happens |
|---|---|---|
| `counterparty` table in MSSQL | **Remove** | Moves to MDM service's own Postgres DB |
| `trade.counterparty_id` column | **Change** | Now `counterparty_mdm_id VARCHAR(50)` — references MDM canonical ID |
| `services/trade-service/internal/risk/credit.go` | **Change** | Fetches credit limit from MDM API instead of local join |
| `services/trade-service/internal/handlers/` | **Change** | Credit check calls MDM before accepting a trade |
| `scripts/init_mssql.sql` | **Change** | Remove counterparty DDL and seed data |
| `docker-compose.yml` | **Add** | Two new containers: MDM service + MDM Postgres |
| `services/mdm-service/` | **New** | Entire new Go service |
| `infra/grafana/dashboards/` | **Add** | New MDM stewardship dashboard |
| Kafka topics | **Add** | `counterparty.updated` topic |
| `.env` | **Add** | MDM service URL + Postgres connection |

---

## New Project Structure (MDM Addition)

Add alongside `services/trade-service/`:

```
services/
└── mdm-service/
    ├── Dockerfile
    ├── go.mod
    ├── cmd/
    │   └── server/main.go          # HTTP server
    ├── internal/
    │   ├── models/
    │   │   └── counterparty.go     # GoldenRecord, IncomingRecord structs
    │   ├── handlers/
    │   │   ├── counterparty.go     # GET/POST/PUT /counterparties
    │   │   └── stewardship.go      # GET/POST /stewardship/queue
    │   ├── db/
    │   │   └── postgres.go         # Postgres connection
    │   ├── matcher/
    │   │   └── match.go            # Match/merge engine
    │   └── publisher/
    │       └── kafka.go            # Publishes counterparty.updated events
    └── tests/

scripts/
└── init_mdm_postgres.sql           # MDM DB schema + seed data

infra/
└── grafana/dashboards/
    └── mdm-stewardship.json        # New Grafana dashboard
```

---

## 3-Day Sprint Plan

### Day 1: Infrastructure (Get Everything Running)

**Morning — Docker + Databases** 🟢 CRITICAL

| # | Task | Done When |
|---|------|-----------|
| 1 | Create project folder structure (see `IMPLEMENTATION_PLAN.md` → Project Structure) — include `services/mdm-service/` | Folders exist |
| 2 | Write `docker-compose.yml` with ALL services: ClickHouse, MSSQL, Kafka+Zookeeper, Redis, Prometheus, Grafana, LocalStack, Superset, **MDM Postgres, MDM Service** | File exists |
| 3 | `docker compose up -d` | All containers healthy (including mdm-postgres + mdm-service) |
| 4 | Connect to MSSQL via DBeaver (`localhost:1433`, `sa`, `YourStr0ngPass1`), run `scripts/init_mssql.sql` — **no counterparty table** (it lives in MDM now). `trade` table uses `counterparty_mdm_id VARCHAR(50)` instead of `counterparty_id INT` | Tables + seed data exist |
| 5 | Run `make clickhouse-init` (or run `scripts/init_clickhouse.sql` in DBeaver on port 8123) | ClickHouse tables + seed data exist |
| 6 | Verify MDM Postgres (`localhost:5432`, `mdm`, `mdmpass`): `golden_record` seeded with 3 counterparties (MDM-001 Tokyo Energy Corp, MDM-002 AUS Grid Partners, MDM-003 NZ Renewable Trust) | `SELECT * FROM golden_record` returns 3 rows |

**Afternoon — Infra + Monitoring**

| # | Task | Done When |
|---|------|-----------|
| 7 | Write Terraform config (`infra/terraform/main.tf`) for LocalStack — S3 buckets + VPC | `terraform apply` succeeds |
| 8 | Set up Prometheus scrape configs (`infra/prometheus/prometheus.yml`) | Prometheus targets show UP |
| 9 | Import Grafana dashboard JSON (`infra/grafana/dashboards/`) | Grafana shows system metrics |
| 10 | Create ClickHouse + MSSQL reporting views (`make powerbi-views` + run `scripts/powerbi_views_mssql.sql` in DBeaver) | Views queryable |
| 11 | Run `make s3-init` | S3 buckets exist in LocalStack |
| 12 | Create `counterparty.updated` Kafka topic | Topic exists |

**Day 1 done criteria:** `docker compose up` brings up everything. Can query all three databases (MSSQL, ClickHouse, MDM Postgres). `golden_record` table seeded with 3 counterparties. MDM service container starts without errors. `counterparty.updated` Kafka topic exists. Grafana shows system metrics. S3 buckets exist in LocalStack. `make check-health` passes.

```bash
# Verify Day 1
make check-health
make clickhouse-shell   # run: SELECT count() FROM market_data
make kafka-topics       # should list trade.events, market.prices, counterparty.updated, etc.
# Verify MDM Postgres
docker exec -it mdm-postgres psql -U mdm -d mdm -c "SELECT * FROM golden_record;"
```

**docker-compose.yml additions for MDM:**

```yaml
mdm-postgres:
  image: postgres:16-alpine
  ports: ["5432:5432"]
  environment:
    POSTGRES_DB: mdm
    POSTGRES_USER: mdm
    POSTGRES_PASSWORD: mdmpass
  volumes:
    - mdm-postgres-data:/var/lib/postgresql/data
    - ./scripts/init_mdm_postgres.sql:/docker-entrypoint-initdb.d/init.sql

mdm-service:
  build: ./services/mdm-service
  ports: ["8081:8081"]
  depends_on: [mdm-postgres, kafka]
  environment:
    MDM_POSTGRES_URL: postgres://mdm:mdmpass@mdm-postgres:5432/mdm
    KAFKA_BROKERS: kafka:9092
    MDM_PORT: 8081
```

**.env additions:**

```bash
# ── MDM Service ──
MDM_SERVICE_URL=http://localhost:8081
MDM_POSTGRES_URL=postgres://mdm:mdmpass@localhost:5432/mdm
```

**scripts/init_mssql.sql changes:**

```sql
-- REMOVE the entire counterparty table DDL and seed data
-- CHANGE in trade table:
--   BEFORE: counterparty_id INT NOT NULL
--   AFTER:  counterparty_mdm_id VARCHAR(50) NOT NULL  -- references MDM-001, MDM-002, etc.
```

**New: scripts/init_mdm_postgres.sql:**

```sql
CREATE TABLE golden_record (
    mdm_id              VARCHAR(50) PRIMARY KEY,    -- e.g. 'MDM-001'
    canonical_name      VARCHAR(200) NOT NULL,
    short_code          VARCHAR(20) UNIQUE,
    credit_limit        DECIMAL(18,2),
    collateral_amount   DECIMAL(18,2) DEFAULT 0,
    currency            VARCHAR(10) DEFAULT 'JPY',
    is_active           BOOLEAN DEFAULT TRUE,
    data_steward        VARCHAR(100),
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    updated_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE incoming_record (
    record_id           SERIAL PRIMARY KEY,
    source_system       VARCHAR(50) NOT NULL,       -- 'TRADING_DESK', 'BROKER_FEED', 'INVOICE_SYSTEM'
    source_id           VARCHAR(50) NOT NULL,
    raw_name            VARCHAR(200) NOT NULL,
    credit_limit        DECIMAL(18,2),
    received_at         TIMESTAMPTZ DEFAULT NOW(),
    match_status        VARCHAR(20) DEFAULT 'PENDING', -- PENDING, AUTO_MERGED, QUEUED, NEW
    matched_mdm_id      VARCHAR(50) REFERENCES golden_record(mdm_id),
    match_score         DECIMAL(5,2)
);

CREATE TABLE stewardship_queue (
    queue_id            SERIAL PRIMARY KEY,
    record_a_id         INT REFERENCES incoming_record(record_id),
    record_b_id         INT REFERENCES incoming_record(record_id),
    conflict_fields     JSONB,
    status              VARCHAR(20) DEFAULT 'OPEN',
    resolved_by         VARCHAR(100),
    resolution          JSONB,
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    resolved_at         TIMESTAMPTZ
);

INSERT INTO golden_record (mdm_id, canonical_name, short_code, credit_limit, currency) VALUES
  ('MDM-001', 'Tokyo Energy Corp',    'TEC',     5000000, 'JPY'),
  ('MDM-002', 'AUS Grid Partners',    'AGP',     3000000, 'AUD'),
  ('MDM-003', 'NZ Renewable Trust',   'NZRT',    2000000, 'NZD');
```

**Kafka topic creation:**

```bash
docker exec -it kafka kafka-topics --create \
  --bootstrap-server localhost:9092 \
  --topic counterparty.updated \
  --partitions 3 \
  --replication-factor 1
```

---

### Day 2: Data + Trading Logic (Core ETRM + MDM)

**Morning — Go Services + Trade Ingestion** 🟢 CRITICAL

| # | Task | Done When |
|---|------|-----------|
| 1 | Bootstrap ETRM Go service: `services/trade-service/` with `go mod init` | Compiles |
| 2 | Bootstrap MDM Go service: `services/mdm-service/` with `go mod init` | Compiles |
| 3 | Kafka consumer for `trade.events` topic | Consumes test messages |
| 4 | Trade ingestion: parse event → insert MSSQL → explode to ClickHouse | Trade appears in both DBs |
| 5 | REST endpoints: `GET /trades`, `GET /trades/:id`, `POST /trades` | curl returns data |
| 6 | Trade explosion logic (break trade into half-hour intervals using `delivery_profile` + `half_hour_intervals`) | `transaction_exploded` populated |
| 7 | MDM REST API endpoints (see below) | All endpoints respond |

**MDM REST API endpoints** (`services/mdm-service/internal/handlers/`):

```
GET  /counterparties           → list all golden records
GET  /counterparties/:mdm_id   → get one golden record (ETRM calls this for credit check)
POST /counterparties/ingest    → receive a record from a source system → runs match/merge
PUT  /counterparties/:mdm_id   → update a golden record (steward uses this)

GET  /stewardship/queue        → list open conflicts
POST /stewardship/queue/:id/resolve → steward submits resolution
```

**MDM models** (`services/mdm-service/internal/models/counterparty.go`):

```go
type GoldenRecord struct {
    MDMID           string  `json:"mdm_id"`
    CanonicalName   string  `json:"canonical_name"`
    ShortCode       string  `json:"short_code"`
    CreditLimit     float64 `json:"credit_limit"`
    Currency        string  `json:"currency"`
    IsActive        bool    `json:"is_active"`
}

type IncomingRecord struct {
    SourceSystem    string  `json:"source_system"`
    SourceID        string  `json:"source_id"`
    RawName         string  `json:"raw_name"`
    CreditLimit     float64 `json:"credit_limit"`
}
```

**MDM match/merge engine** (`services/mdm-service/internal/matcher/match.go`):

```go
func ScoreMatch(incoming IncomingRecord, existing GoldenRecord) float64 {
    score := 0.0
    if strings.EqualFold(incoming.RawName, existing.ShortCode) {
        score += 60
    }
    incomingUpper := strings.ToUpper(incoming.RawName)
    existingUpper := strings.ToUpper(existing.CanonicalName)
    if strings.Contains(existingUpper, incomingUpper) ||
       strings.Contains(incomingUpper, existingUpper) {
        score += 30
    }
    return score
}

func Route(score float64) string {
    if score >= 90 { return "AUTO_MERGE" }
    if score >= 60 { return "QUEUE" }       // send to stewardship
    return "NEW"                            // create new golden record
}
```

**Afternoon — P&L + Settlement + MDM Integration**

| # | Task | Done When |
|---|------|-----------|
| 8 | P&L calculation: query `transaction_exploded FINAL`, compute realized + unrealized | `GET /pnl/:trade_id` returns breakdown |
| 9 | MTM curve service 🟡 MOCK — hardcoded synthetic curves per market (JEPX ~10 JPY/kWh, NEM ~80 AUD/MWh, NZEM ~60 NZD/MWh) | Curves in ClickHouse `mtm_curve` |
| 10 | Settlement stub: generate invoice from delivered intervals, basic match logic | `GET /settlement/:trade_id` returns invoice |
| 11 | **Credit check: calls MDM API** (`GET /counterparties/:mdm_id`) to get credit limit instead of local MSSQL join | Over-limit trade returns 400 |
| 12 | Market data generator 🟡 MOCK — synthetic prices published to Kafka every 30s | Prices flowing into ClickHouse `market_data` |
| 13 | **MDM Kafka publisher**: when golden record changes, publish to `counterparty.updated` | Events appear in Kafka |
| 14 | **ETRM Kafka consumer**: listen to `counterparty.updated`, cache in Redis | Redis has counterparty data |

**Credit check change** (`services/trade-service/internal/risk/credit.go`):

```go
// BEFORE: local DB join
row := db.QueryRow("SELECT credit_limit FROM counterparty WHERE counterparty_id = ?", id)

// AFTER: HTTP call to MDM service
resp, err := http.Get(os.Getenv("MDM_SERVICE_URL") + "/counterparties/" + mdmID)
var record GoldenRecord
json.NewDecoder(resp.Body).Decode(&record)
creditLimit := record.CreditLimit
```

**MDM Kafka publisher** (`services/mdm-service/internal/publisher/kafka.go`):

```go
func PublishUpdate(record GoldenRecord) {
    payload, _ := json.Marshal(record)
    writer.WriteMessages(ctx, kafka.Message{
        Topic: "counterparty.updated",
        Key:   []byte(record.MDMID),
        Value: payload,
    })
}
```

**ETRM counterparty cache** (`services/trade-service/internal/kafka/`):

```go
// Listen to counterparty.updated
// On message: SET redis key "counterparty:{mdm_id}" = JSON payload, TTL 1hr
```

**Day 2 done criteria:** Can POST a trade via API, see it exploded in ClickHouse, get P&L breakdown (realized + unrealized), generate an invoice, and see market prices flowing into ClickHouse. `POST /counterparties/ingest` with a known name returns AUTO_MERGE. An ambiguous name lands in the stewardship queue. Credit check on a new trade calls MDM. `counterparty.updated` events appear in Kafka when a record changes.

```bash
# Verify Day 2
curl -X POST localhost:8080/trades -d '{"unique_id":"TEST-001",...}'
curl localhost:8080/trades/TEST-001
curl localhost:8080/pnl/TEST-001
curl localhost:8080/settlement/TEST-001

# Verify MDM
curl localhost:8081/counterparties
curl localhost:8081/counterparties/MDM-001
curl -X POST localhost:8081/counterparties/ingest \
  -d '{"source_system":"BROKER_FEED","raw_name":"TEC","credit_limit":4500000}'
curl localhost:8081/stewardship/queue
```

---

### Day 3: Dashboard + Validation (Make It Visible)

**Morning — Dashboards**

| # | Task | Done When |
|---|------|-----------|
| 1 | Grafana: Trade Blotter dashboard (MSSQL datasource) | Shows active trades |
| 2 | Grafana: P&L Monitor dashboard (ClickHouse datasource) | Shows realized vs unrealized by trade |
| 3 | Grafana: Market Data dashboard (ClickHouse) | Price charts by area (JEPX/NEM/NZEM) |
| 4 | Grafana: Invoice Matching dashboard | Status breakdown (matched/error/pending) |
| 5 | Grafana: System Health dashboard | Kafka lag, DB query times |
| 6 | Grafana alerts: P&L threshold breach, invoice mismatch, Kafka lag > 1000 | Alerts configured |
| 7 | **Grafana: MDM Stewardship dashboard** (MDM Postgres datasource) — see panels below | Dashboard shows MDM metrics |

**MDM Stewardship Dashboard** (`infra/grafana/dashboards/mdm-stewardship.json`) — four panels:

| Panel | Query | Purpose |
|---|---|---|
| Golden Record Count | `SELECT COUNT(*) FROM golden_record WHERE is_active` | How many canonical counterparties exist |
| Stewardship Queue Depth | `SELECT COUNT(*) FROM stewardship_queue WHERE status = 'OPEN'` | How many conflicts need human review |
| Match Distribution | `SELECT match_status, COUNT(*) FROM incoming_record GROUP BY match_status` | Pie chart: AUTO_MERGE vs QUEUED vs NEW |
| Recent Ingestions | `SELECT source_system, raw_name, match_status, match_score FROM incoming_record ORDER BY received_at DESC LIMIT 20` | Live feed of what's coming in |

**Afternoon — CI + End-to-End Validation**

| # | Task | Done When |
|---|------|-----------|
| 8 | 🔴 GitHub Actions CI pipeline (`.github/workflows/ci.yml`) — build + test + lint | Pipeline passes on push |
| 9 | Superset: build business reporting dashboard (see Lab 3) | Dashboard shows trades + P&L |
| 10 | End-to-end scenario run — ETRM (see below) | All steps pass |
| 11 | **End-to-end scenario run — MDM (see below)** | All steps pass |
| 12 | Document what you skipped (see "What I'm Deliberately Skipping") | List reviewed |

**End-to-end scenario (ETRM):**
1. Ingest 10 trades (mix of PHYSICAL/FINANCIAL, STANDARD/CONSTANT/VARIABLE)
2. Let market data flow for 5 minutes
3. Run P&L calc
4. Run settlement for completed trades
5. Check Grafana dashboards show everything
6. Verify credit limits block over-limit trade

**End-to-end scenario (MDM):**
1. Send a known counterparty: `POST /counterparties/ingest {"source_system":"BROKER_FEED","raw_name":"TEC","credit_limit":4500000}` — should AUTO_MERGE to MDM-001 (Tokyo Energy Corp)
2. Send an ambiguous one: `POST /counterparties/ingest {"source_system":"INVOICE_SYSTEM","raw_name":"Tokyo Energy","credit_limit":6000000}` — should land in stewardship queue with a conflict on `credit_limit`
3. Resolve it: `POST /stewardship/queue/1/resolve {"credit_limit":4750000}` — MDM updates the golden record and publishes `counterparty.updated`
4. Check Kafka: the update event should appear in the `counterparty.updated` topic
5. Check Redis: ETRM cache should reflect the new credit limit within seconds
6. Try posting a trade that would exceed the new limit — should be rejected

**Day 3 done criteria:** Full end-to-end demo works for both ETRM and MDM flows. Grafana dashboards are populated (including MDM stewardship). CI pipeline runs. You can walk someone through every component.

---

## Labs (Hands-On Practice)

Do these after the 3-day sprint, or dip into them whenever you're stuck on a concept. Each lab is self-contained.

| Lab | Topic | File | Time |
|-----|-------|------|------|
| Lab 1 | Databases: MSSQL + ClickHouse | `docs/labs/lab1_databases.md` | 60 min |
| Lab 2 | Kafka: Topics & Consumer Lag | `docs/labs/lab2_kafka.md` | 30 min |
| Lab 3 | Superset: Business Reporting | `docs/labs/lab3_superset_reporting.md` | 60 min |
| Lab 4 | P&L Investigation Scenario | `docs/labs/lab4_pnl_investigation.md` | 45 min |
| Lab 5 | Terraform & LocalStack | `docs/labs/lab5_terraform.md` | 45 min |
| Lab 6 | Grafana & Prometheus Monitoring | `docs/labs/lab6_monitoring.md` | 60 min |
| Lab 7 | GitHub Actions CI/CD | `docs/labs/lab7_cicd.md` | 45 min |
| Lab 8 | Networking & VPC Concepts | `docs/labs/lab8_networking.md` | 35 min |
| Lab 9 | MDM: Golden Records, Match/Merge, Stewardship | `docs/labs/lab9_mdm.md` | 45 min |

**Total lab time: ~7.25 hours**

---

## Guides (Reference — Read As Needed)

| Guide | File | What It Covers |
|-------|------|---------------|
| ETRM Concepts | `docs/etrm_concepts.md` | Trading domain: trades, P&L, settlement, credit risk |
| ClickHouse Cookbook | `docs/clickhouse_queries.md` | 9 query patterns: FINAL, argMax, time travel, etc. |
| SQL Cookbook | `docs/sql_query_cookbook.md` | MSSQL queries traders actually ask for |
| Kafka Guide | `docs/kafka_guide.md` | Topics, offsets, consumer groups, debugging |
| Learning Roadmap | `docs/learning_roadmap.md` | Layer-by-layer breakdown, interview questions |
| Power BI Setup | `docs/powerbi_setup.md` | Windows VM + Power BI connections (optional) |
| Power BI DAX | `docs/powerbi_dax_measures.md` | Ready-to-use DAX formulas (optional) |

---

## Makefile Shortcuts

```bash
make up              # Start all containers
make down            # Stop all containers
make wipe            # Stop + delete all data volumes
make ps              # Show container status
make check-health    # Verify everything is healthy
make clickhouse-init # Run ClickHouse DDL + seed data
make powerbi-views   # Create ClickHouse reporting views
make s3-init         # Create S3 buckets in LocalStack
make clickhouse-shell # Open ClickHouse CLI
make kafka-topics    # List Kafka topics
```

---

## What I'm Deliberately Skipping

See `IMPLEMENTATION_PLAN.md` → "What I Am Deliberately Skipping" for the full ETRM list. Key items:

| Item | Why | When to Add |
|------|-----|-------------|
| Real AWS deployment | LocalStack is sufficient; real AWS costs money | Post-sprint |
| EKS / Kubernetes | >2 hours; Docker Compose gives same learning | Post-sprint |
| ArgoCD | Requires K8s; stubbed in CI pipeline | After EKS |
| Microsoft Entra ID | Requires Azure AD tenant; stubbed with local JWT | Post-sprint |
| Zscaler | Enterprise product; Docker network isolation demos the concept | Learn conceptually |
| Rust services | Go is faster to prototype; same interfaces | Post-sprint |
| Real market data APIs | Registration needed; synthetic data teaches same patterns | Post-sprint |
| VaR / scenario analysis | Needs quant formulas; hardcoded stub is sufficient | When you get actual formulas |
| **LEI lookup** | Real Legal Entity Identifier validation requires a paid API | When you have access to GLEIF free tier |
| **Full fuzzy matching library** | Levenshtein/Jaro-Winkler adds complexity; simple string match teaches the concept | Week 5+: add `go-text/similarity` |
| **Stewardship UI** | A proper React UI takes a full day; the Grafana dashboard + API calls demonstrate the concept | Week 5+: build a simple React form |
| **Multi-entity MDM** | Only counterparty is extracted; market areas and curves stay in ETRM | Week 6+: extract `curve` table too |
| **MDM audit trail** | Change history on golden records is important in production; skipped here | Week 3: add `golden_record_history` table |

---

## How MDM Maps to Learning Guide Phases

| Learning Guide Phase | MDM work that fits here |
|---|---|
| Phase 1 — Foundation | Read this doc. Understand why `counterparty` moved out of MSSQL. |
| Phase 2 — Reporting | Add the MDM Grafana dashboard. Query `golden_record` and `stewardship_queue` in DBeaver. |
| Phase 3 — Infrastructure | MDM Postgres container in docker-compose. New Kafka topic. `.env` additions. |
| Phase 4 — Deep Dive | Trace a counterparty conflict end-to-end: ingest → queue → resolve → Kafka event → ETRM cache update → credit check. |

---

## After the Sprint: Deep Dive Path

Once the sandbox is running, go deeper:

1. **Trace the full trade lifecycle** — Pick `TRADE-JP-001`. Find it in MSSQL. Find its intervals in ClickHouse. Calculate P&L by hand. Check the MTM curve. Generate an invoice mentally.
2. **Trace the MDM lifecycle** — Send a counterparty through ingest. Watch it match/merge. Resolve a stewardship conflict. See the Kafka event propagate to ETRM cache.
3. **Do the labs in order** — Lab 1 through Lab 8. They build on each other.
4. **Study the init scripts** — `scripts/init_clickhouse.sql` shows how trades are exploded into half-hour slots. `scripts/init_mdm_postgres.sql` shows the MDM schema.
5. **Answer the interview questions** — See `docs/learning_roadmap.md`.
6. **Optional extensions:**
   - Power BI (Windows VM) — `docs/powerbi_setup.md`
   - Real AWS deployment — modify `infra/terraform/main.tf`
   - APAC market deep dive — research JEPX bidding, NEM dispatch, NZEM hydro scheduling
   - MDM stewardship React UI
   - Extract more entities into MDM (curves, market areas)

---

## Job Scope Coverage Map

| Job Scope Item | Covered By |
|---|---|
| ClickHouse and MSSQL cloud configuration | Lab 1, ClickHouse Cookbook, SQL Cookbook |
| AWS resource deployment using Terraform | Lab 5 |
| AWS networking: VPC segmentation | Lab 8 |
| AWS EKS architecture | Lab 8 (conceptual), IMPLEMENTATION_PLAN.md |
| Prometheus/Grafana metrics | Lab 6 |
| GitHub Actions and CI/CD | Lab 7 |
| Microsoft Entra ID and Zscaler | Lab 8 (Zscaler section), IMPLEMENTATION_PLAN.md (mocked) |
| Power BI multi-database connectivity | Power BI Setup + DAX guides (optional) |
| ETRM systems and core functions | ETRM Concepts guide, all labs |
| Energy products: options, futures, PPAs, spot | ETRM Concepts guide |
| P&L calculation, attribution, MTM | Lab 4, ClickHouse Cookbook Patterns 3-6 |
| Trade reconciliation and settlement | Lab 4, SQL Cookbook settlement queries |
| Credit risk and exposure limits | Lab 1 Task A4, SQL Cookbook risk queries, **MDM credit check flow** |
| VaR and scenario analysis | Learning Roadmap (research topic) |
| APAC markets: NEM, JEPX, NZEM | Seed data covers all 3, ETRM Concepts guide |
| Imbalance settlement | ETRM Concepts guide (Physical vs Financial section) |
| **Master Data Management** | MDM service, match/merge engine, stewardship queue, Grafana MDM dashboard |
| **Data governance / stewardship** | Stewardship queue, conflict resolution flow, golden record concept |
| **Cross-system data integration** | ETRM → MDM API calls, Kafka `counterparty.updated` events, Redis cache |

# Lab 15 — System Design: Architect an ETRM from Scratch

**Prereqs:** Labs 1-14 complete (or at least understood). This is the capstone.
**Time:** 90-120 minutes
**Goal:** Design, justify, and present a complete ETRM architecture — the way you would in a senior engineering interview or an architecture review.

---

## Why This Matters

This is the lab that ties everything together. You've learned databases, Kafka, Go services, ClickHouse performance, settlement, monitoring, and MDM. Now you need to **think in systems** — not individual components.

Every senior+ engineering interview at a trading firm includes some version of: "Design a system that ingests trades, calculates P&L in real-time, and serves dashboards to 50 traders." If you can whiteboard this with confidence, you're hired.

---

## The Challenge

**Design an ETRM system for an APAC energy trading desk that:**

1. Trades electricity across 3 markets (JEPX, NEM, NZEM)
2. Processes ~100 trades/day, each with 500-2000 half-hour intervals
3. Calculates mark-to-market P&L in near real-time (< 30 seconds stale)
4. Serves dashboards to 50 concurrent users
5. Handles settlement and invoice matching at end of month
6. Manages counterparty master data with a golden record
7. Must survive a single-node failure without data loss
8. Must comply with AEMO reporting (NEM), JEPX pool settlement, and NZ Electricity Authority rules

---

## Part A — Draw the Architecture (30 min)

### Task A1: Component diagram

Draw (on paper, whiteboard, or a diagramming tool) the following components and their connections:

```
┌─────────────────────────────────────────────────────────────────┐
│                        EXTERNAL                                  │
│   Market Data Feeds (JEPX, NEM, NZEM)                           │
│   Counterparty Systems (Banks, Brokers)                          │
│   Regulatory Reporting (AEMO, ASX, NZ EA)                        │
└────────────────────────┬────────────────────────────────────────┘
                         │
                    ┌────▼────┐
                    │  Kafka  │ ← Event backbone
                    └────┬────┘
                         │
         ┌───────────────┼───────────────┐
         │               │               │
    ┌────▼────┐    ┌────▼────┐    ┌────▼────┐
    │  Trade  │    │ Market  │    │  MDM    │
    │ Service │    │ Data    │    │ Service │
    │  (Go)   │    │ Ingester│    │  (Go)   │
    └────┬────┘    └────┬────┘    └────┬────┘
         │               │               │
    ┌────▼────┐    ┌────▼────┐    ┌────▼────┐
    │  MSSQL  │    │ Click-  │    │ Postgres│
    │ (Trades)│    │ House   │    │  (MDM)  │
    └─────────┘    │(Analytics)   └─────────┘
                   └────┬────┘
                        │
              ┌─────────┼─────────┐
              │         │         │
         ┌────▼──┐ ┌───▼───┐ ┌──▼──────┐
         │Grafana│ │Superset│ │Power BI │
         │(Ops)  │ │(Ad-hoc)│ │(Reports)│
         └───────┘ └───────┘ └─────────┘
```

### Task A2: For each component, answer

| Component | Why this technology? | What's the alternative? | Why not the alternative? |
|---|---|---|---|
| MSSQL | ACID transactions for trade booking | PostgreSQL | Firm standard; SQL Server licensing; .NET ecosystem integration |
| ClickHouse | Time-series analytics, 100M row queries in <1s | TimescaleDB, QuestDB | ClickHouse handles our scale; columnar storage for aggregations |
| Kafka | Decoupled event processing, replay capability | RabbitMQ, AWS SQS | Kafka: ordered, persistent, partitioned; RabbitMQ: no replay |
| Go | Fast compilation, concurrency (goroutines), small binary | Java, Rust | Go: simpler than Rust, faster than Java; great for microservices |
| Grafana | Ops dashboards with alerting | Datadog | Open source, Prometheus-native, no per-seat cost |
| Superset | Ad-hoc SQL + charts for traders | Metabase | Supports ClickHouse natively, better SQL Lab |

### Task A3: Data flow diagrams

Draw the flow for these 3 critical paths:

**Path 1: Trade Ingestion**
```
Trader → UI/API → Trade Service → MSSQL (persist) → Kafka (trade.created)
                                                    ↓
                                               Trade Service (consumer)
                                                    ↓
                                               Explode to intervals
                                                    ↓
                                               ClickHouse (batch insert)
```

**Path 2: P&L Calculation**
```
Market Data Feed → Kafka (market.prices) → Ingester → ClickHouse (market_data)
                                                           ↓
                                                  ClickHouse query (FINAL + argMax)
                                                           ↓
                                                  P&L = (mtm_price - contracted_price) × quantity
                                                           ↓
                                                  Superset dashboard / REST API
```

**Path 3: Counterparty Onboarding**
```
Source System → MDM Service → Match/Merge Engine
                                    ↓
                          ┌─────────┼──────────┐
                     Score ≥ 90   60-89      < 60
                          ↓         ↓          ↓
                    AUTO_MERGE   QUEUE     NEW RECORD
                          ↓         ↓          ↓
                    Golden Record  Stewardship  Golden Record
                          ↓         Queue        ↓
                    Kafka (counterparty.updated)
                          ↓
                    Trade Service → Redis Cache
```

---

## Part B — Capacity Planning (20 min)

### Task B1: Back-of-envelope calculations

**Daily data volume:**
```
Trades: 100 trades/day × 1000 intervals avg = 100,000 rows/day in ClickHouse
Market data: 48 slots/day × 3 areas × 1 update = 144 rows/day
              × 10 curve sources = 1,440 rows/day
MTM refresh: 100 trades × 1000 intervals = 100,000 P&L recalcs at each curve update
```

**Monthly:**
```
ClickHouse: 100K rows/day × 22 trading days = 2.2M rows/month
Growth: linear, ~26M rows/year
Storage: 26M rows × ~200 bytes/row = ~5 GB/year (ClickHouse compresses ~10x → 500 MB)
```

**Query performance targets:**
```
P&L summary (5 trades): < 100ms
P&L summary (1000 trades): < 2 seconds
Market price lookup: < 50ms
Full interval drill-down: < 500ms
Dashboard load (10 charts): < 3 seconds total
```

### Task B2: Identify bottlenecks

At current scale (100 trades/day), nothing is a bottleneck. But what if the desk grows to 10,000 trades/day?

| Component | Current | At 10K trades/day | Solution |
|---|---|---|---|
| ClickHouse inserts | 100K/day | 10M/day | Increase batch size, add sharding |
| P&L calculation | 100K intervals | 10M intervals | Pre-aggregate with materialized views |
| Kafka throughput | 144 msgs/day | 14.4K msgs/day | Still trivial for Kafka (handles millions/sec) |
| MSSQL writes | 100 trades/day | 10K trades/day | Add connection pooling, batch inserts |
| Superset queries | 5 concurrent | 50 concurrent | Add read replicas, cache layer |

### Task B3: Failure modes

For each component, answer: **what happens when it dies?**

| Component | Impact | Recovery | Data loss? |
|---|---|---|---|
| MSSQL down | Can't book new trades | Restart, replicate from standby | No (WAL + backup) |
| ClickHouse down | P&L stale, dashboards broken | Restart, re-ingest from Kafka | No (Kafka retention) |
| Kafka down | No events flow, all services continue with stale data | Restart Zookeeper + Kafka | No (disk persistence) |
| Trade Service down | Can't book trades, P&L stops updating | Restart, Kafka catches up | No (idempotent) |
| MDM Service down | Can't onboard new counterparties | Restart, Redis cache still warm | No |
| Redis down | Credit check calls hit MDM API directly | Restart, Kafka repopulates | No |
| Grafana down | No monitoring dashboards | Restart (stateless, config in Git) | No |

---

## Part C — Security Architecture (15 min)

### Task C1: Network segmentation

```
┌─────────────────────────────────────────────────────┐
│ VPC: 10.124.0.0/16                                   │
│                                                       │
│  ┌─── Public Subnet (10.124.1.0/24) ──────────────┐ │
│  │  ALB (HTTPS termination)                         │ │
│  │  WAF (OWASP rules)                               │ │
│  └──────────────────────────────────────────────────┘ │
│                                                       │
│  ┌─── App Subnet (10.124.10.0/24) ─────────────────┐ │
│  │  Trade Service  MDM Service  Superset  Grafana   │ │
│  │  (port 8080)    (port 8081)  (8088)    (3000)    │ │
│  └──────────────────────────────────────────────────┘ │
│                                                       │
│  ┌─── Data Subnet (10.124.20.0/24) ────────────────┐ │
│  │  MSSQL    ClickHouse    Redis    MDM Postgres    │ │
│  │  (1433)   (9000/8123)   (6379)   (5432)          │ │
│  └──────────────────────────────────────────────────┘ │
│                                                       │
│  ┌─── Messaging Subnet (10.124.30.0/24) ───────────┐ │
│  │  Kafka (9092)    Zookeeper (2181)                │ │
│  └──────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
```

### Task C2: Security controls checklist

- [ ] **Authentication:** Microsoft Entra ID (formerly Azure AD) for all user-facing apps
- [ ] **Authorization:** RBAC — traders see their book only, risk managers see all
- [ ] **Encryption in transit:** TLS 1.3 between all services
- [ ] **Encryption at rest:** AES-256 for MSSQL TDE, ClickHouse disk encryption
- [ ] **Secrets management:** AWS Secrets Manager or HashiCorp Vault (not .env files!)
- [ ] **Audit logging:** every trade creation, every P&L query, every MDM change
- [ ] **Network:** no database ports exposed to internet — app subnet only
- [ ] **Zscaler/ZPA:** zero-trust access for remote users (no VPN)

---

## Part D — Present Your Design (30 min)

### Task D1: Write a one-page architecture document

Structure:
```markdown
# ETRM Architecture — APAC Energy Trading Desk

## Problem Statement
[2-3 sentences on what we're solving]

## Key Decisions
1. Dual-database (MSSQL + ClickHouse) because...
2. Kafka event backbone because...
3. MDM as separate service because...

## Data Flow
[Include the 3 paths from Part A]

## Scale Targets
[Include the capacity numbers from Part B]

## Failure Handling
[Include the failure modes table from Part B]

## Security
[Include the network diagram and controls from Part C]

## Trade-offs
1. We chose X over Y because...
2. We accept Z limitation because...
```

### Task D2: Practice the 5-minute pitch

Imagine you're presenting to:
1. **CTO:** Focus on technology choices and scalability
2. **Head of Trading:** Focus on latency, P&L accuracy, and dashboard responsiveness
3. **CISO:** Focus on security, access control, and audit trails
4. **CFO:** Focus on infrastructure cost and build-vs-buy decisions

Each audience cares about different things. Practice explaining the same system from each perspective.

### Task D3: Anticipate the hard questions

Prepare answers for:
1. "Why not just use Bloomberg for market data and skip building this?" (Bloomberg Terminal costs $24K/year/seat × 50 seats = $1.2M/year. Our system costs ~$50K/year in infra.)
2. "What if ClickHouse can't handle our scale in 3 years?" (Horizontal sharding, or migrate hot data to Apache Druid / ClickHouse Cloud.)
3. "Why Go and not Java? Our team knows Java." (Valid concern. Go is simpler for microservices, but if team knows Java, use Java. Technology choice matters less than team velocity.)
4. "How do you handle regulatory reporting for 3 different markets?" (Each market has a reporting adapter. AEMO uses MMS data model, JEPX uses pool settlement format, NZ EA uses reconciliation manager format. Adapters are separate services.)

---

## Checkpoint: What You Should Be Able to Do

- [ ] Draw a complete ETRM architecture with all major components
- [ ] Justify every technology choice with trade-offs
- [ ] Calculate back-of-envelope capacity for your system
- [ ] Identify every failure mode and explain recovery
- [ ] Present the architecture to different audiences (CTO, trader, CISO, CFO)
- [ ] Answer hard questions about alternatives and limitations
- [ ] Write a concise architecture document that a new engineer could understand

---

## What Makes This World-Class

Most engineers can build components. World-class engineers **think in systems**:

1. **They know why** — not just what each component does, but why it was chosen over alternatives
2. **They know the numbers** — "100K rows/day, 500MB/year, <100ms P95 latency"
3. **They know the failures** — "if Kafka dies, we have 7 days of replay; if ClickHouse dies, we re-ingest from Kafka"
4. **They know the audience** — the CTO wants scalability, the trader wants speed, the CISO wants controls
5. **They know the trade-offs** — "we chose eventual consistency over strong consistency for P&L because..."

This is the difference between "I use ClickHouse" and "I chose ClickHouse because our access pattern is append-only time-series with heavy aggregation, and columnar storage gives us 10-100x query performance over MSSQL for these workloads, while MSSQL retains ACID guarantees for trade booking where correctness matters more than speed."

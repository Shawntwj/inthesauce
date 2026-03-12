# Master Guide — ETRM Sandbox Learning Path

This is your single starting point. It tells you what to do, in what order, and how long each piece takes. Follow it top to bottom.

---

## Before You Start

### Prerequisites
| Tool | Install Command | What It's For |
|------|----------------|---------------|
| Docker Desktop | [docker.com](https://www.docker.com/products/docker-desktop/) | Runs all services |
| DBeaver | `brew install --cask dbeaver-community` | SQL client for MSSQL + ClickHouse |
| Terraform | `brew install terraform` | Infrastructure as Code |
| AWS CLI | `brew install awscli` | Interact with S3 (LocalStack) |
| Git | pre-installed on macOS | Version control |

### First Boot (do once)
```bash
# 1. Start the stack
make up

# 2. Wait ~2 min for all containers to start, then verify
make check-health

# 3. Initialise ClickHouse (creates tables + seed data)
make clickhouse-init

# 4. Initialise MSSQL (Azure SQL Edge doesn't auto-run init scripts)
#    Open DBeaver → connect to localhost:1433, user sa, password YourStr0ngPass1
#    Open scripts/init_mssql.sql → Execute All

# 5. Create reporting views
make powerbi-views
#    Then in DBeaver (MSSQL/etrm), execute scripts/powerbi_views_mssql.sql

# 6. Initialise S3 buckets
make s3-init

# 7. Verify everything
make check-health
```

### Key URLs
| Service | URL | Credentials |
|---------|-----|-------------|
| Superset | http://localhost:8088 | admin / admin |
| Grafana | http://localhost:3000 | admin / admin |
| Prometheus | http://localhost:9090 | none |
| ClickHouse HTTP | http://localhost:8123 | default / (blank) |
| MSSQL | localhost:1433 | sa / YourStr0ngPass1 |
| LocalStack | http://localhost:4566 | test / test |

---

## The Learning Path

### Phase 1: Foundation (Week 1) — ~6 hours total

**Goal:** Understand what's running, how the databases work, and what energy trading looks like.

| Order | What | Time | Notes |
|-------|------|------|-------|
| 1 | Read `docs/etrm_concepts.md` | 30 min | Read this first. It explains the entire domain. |
| 2 | Read `docker-compose.yml` | 20 min | Understand every service and port. |
| 3 | **Lab 1** — Databases | 60 min | `docs/labs/lab1_databases.md` — MSSQL + ClickHouse + Superset SQL Lab |
| 4 | Read `docs/clickhouse_queries.md` | 30 min | Run every query. Understand FINAL, argMax, COALESCE. |
| 5 | Read `docs/sql_query_cookbook.md` | 30 min | Run the trader-style queries. |
| 6 | Read `docs/kafka_guide.md` | 20 min | Understand topics, offsets, consumer groups. |
| 7 | **Lab 2** — Kafka | 30 min | `docs/labs/lab2_kafka.md` — list topics, consume messages, publish a test message. |

**Checkpoint:** You should be able to:
- Query both databases confidently
- Explain the difference between MSSQL (transactional) and ClickHouse (analytics)
- Explain what `FINAL` and `argMax` do
- List Kafka topics and explain what each carries

---

### Phase 2: Reporting & Business Context (Week 2) — ~4 hours total

**Goal:** Build the dashboards that traders and risk managers actually use.

| Order | What | Time | Notes |
|-------|------|------|-------|
| 8 | **Lab 3** — Superset Reporting | 60 min | `docs/labs/lab3_superset_reporting.md` — build a real dashboard for a trader. |
| 9 | **Lab 4** — P&L Investigation | 45 min | `docs/labs/lab4_pnl_investigation.md` — simulate debugging a trader's P&L question. |
| 10 | Re-read `docs/etrm_concepts.md` sections on Settlement and Credit Risk | 20 min | Should make more sense now that you've seen the data. |
| 11 | Run the invoice and settlement queries from `docs/sql_query_cookbook.md` | 30 min | Understand matching, tolerances, overdue logic. |

**Checkpoint:** You should be able to:
- Build a Superset dashboard from scratch
- Investigate a P&L discrepancy systematically (MSSQL → ClickHouse → curve check → time travel)
- Explain realized vs unrealized P&L
- Explain physical vs financial settlement

---

### Phase 3: Infrastructure & DevOps (Week 3) — ~5 hours total

**Goal:** Understand the infrastructure layer — Terraform, monitoring, networking, CI/CD.

| Order | What | Time | Notes |
|-------|------|------|-------|
| 12 | **Lab 5** — Terraform & LocalStack | 45 min | `docs/labs/lab5_terraform.md` — provision S3, modify config, understand IaC. |
| 13 | **Lab 6** — Grafana & Prometheus | 60 min | `docs/labs/lab6_monitoring.md` — build ops dashboards, set up alerts. |
| 14 | **Lab 8** — Networking & VPC | 35 min | `docs/labs/lab8_networking.md` — subnet design, security groups, Zscaler concepts. |
| 15 | **Lab 7** — GitHub Actions CI/CD | 45 min | `docs/labs/lab7_cicd.md` — build a CI pipeline, break it, fix it. |

**Checkpoint:** You should be able to:
- Run `terraform init/plan/apply` and explain what each does
- Build a Grafana dashboard with Prometheus + ClickHouse panels
- Draw a VPC diagram with subnets and explain security groups
- Create a GitHub Actions workflow and explain job dependencies

---

### Phase 4: Deep Dive & Interview Prep (Week 4) — ~4 hours total

**Goal:** Connect the dots. Trace the full lifecycle. Prepare to explain everything.

| Order | What | Time | Notes |
|-------|------|------|-------|
| 16 | Trace the full trade lifecycle | 60 min | Pick TRADE-JP-001. Find it in MSSQL. Find its intervals in ClickHouse. Calculate P&L by hand. Check the MTM curve. Generate an invoice mentally. |
| 17 | Study `scripts/init_clickhouse.sql` | 30 min | Understand how trades are exploded into half-hour slots. This is what the Go service will do. |
| 18 | Review all labs' Checkpoint sections | 30 min | Go through every checkbox. Can you do each one? Re-do any that feel weak. |
| 19 | Answer the interview questions in `docs/learning_roadmap.md` | 45 min | Write out answers. Practice explaining out loud. |
| 20 | Study `IMPLEMENTATION_PLAN.md` — Sections 7-9 (Monitoring, Terraform, CI/CD) | 30 min | Understand how the pieces fit together in production. |

**Checkpoint:** You should be able to:
- Explain the complete trade lifecycle from booking to settlement
- Answer every question in the "Questions to Be Able to Answer" section of `docs/learning_roadmap.md`
- Explain every component in the architecture diagram

---

### Phase 5: Optional Extensions (Week 5+)

These are optional but valuable:

| Topic | Guide | When |
|-------|-------|------|
| Power BI (Windows VM) | `docs/powerbi_setup.md` + `docs/powerbi_dax_measures.md` | When you set up VMware Fusion + Windows 11 ARM |
| Build the Go service | `IMPLEMENTATION_PLAN.md` Day 2 | When you want to write code |
| Real AWS deployment | Modify `infra/terraform/main.tf` to point to real AWS | When you have AWS free tier access |
| APAC market deep dive | Research JEPX bidding, NEM dispatch, NZEM hydro scheduling | When you want domain depth |

---

## Quick Reference: What's Where

### Labs (hands-on, do these)
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

**Total lab time: ~6.5 hours**

### Guides (reference, read as needed)
| Guide | File | What It Covers |
|-------|------|---------------|
| ETRM Concepts | `docs/etrm_concepts.md` | Trading domain: trades, P&L, settlement, credit risk |
| ClickHouse Cookbook | `docs/clickhouse_queries.md` | 9 query patterns: FINAL, argMax, time travel, etc. |
| SQL Cookbook | `docs/sql_query_cookbook.md` | MSSQL queries traders actually ask for |
| Kafka Guide | `docs/kafka_guide.md` | Topics, offsets, consumer groups, debugging |
| Learning Roadmap | `docs/learning_roadmap.md` | Layer-by-layer breakdown, interview questions |
| Power BI Setup | `docs/powerbi_setup.md` | Windows VM + Power BI connections (optional) |
| Power BI DAX | `docs/powerbi_dax_measures.md` | Ready-to-use DAX formulas (optional) |

### Scripts
| Script | Purpose |
|--------|---------|
| `scripts/init_mssql.sql` | Creates MSSQL tables + seed data (run manually in DBeaver) |
| `scripts/init_clickhouse.sql` | Creates ClickHouse tables + seed data (run via `make clickhouse-init`) |
| `scripts/powerbi_views_mssql.sql` | Flat views for reporting (run in DBeaver) |
| `scripts/powerbi_views_clickhouse.sql` | ClickHouse views for reporting (run via `make powerbi-views`) |

### Makefile shortcuts
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

## Pacing Guide

| Pace | Timeline | Schedule |
|------|----------|----------|
| **Intensive** (full-time) | 1 week | Phases 1-3 in 5 days, Phase 4 on weekend |
| **Moderate** (2-3 hrs/day) | 2-3 weeks | One phase per week |
| **Casual** (1 hr/day) | 4-5 weeks | One phase per week, labs split across days |

**Recommended approach:** Do one lab per sitting. Don't rush — it's better to deeply understand Lab 1 than to skim through all 8. If a concept doesn't click, re-read the corresponding guide (e.g. stuck on ClickHouse? Re-read `docs/clickhouse_queries.md` before moving to Lab 2).

---

## Job Scope Coverage Map

How each lab/guide maps to the job scope you'll encounter:

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
| Credit risk and exposure limits | Lab 1 Task A4, SQL Cookbook risk queries |
| VaR and scenario analysis | Learning Roadmap (research topic) |
| APAC markets: NEM, JEPX, NZEM | Seed data covers all 3, ETRM Concepts guide |
| Imbalance settlement | ETRM Concepts guide (Physical vs Financial section) |

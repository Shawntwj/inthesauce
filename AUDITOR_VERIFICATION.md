# Auditor Verification Prompt — ETRM Sandbox & Learning Labs

**Copy-paste this entire prompt to a separate Claude (or any LLM) session. Point it at this repository and let it run the full audit.**

---

## PROMPT START

You are an independent auditor reviewing an Energy Trading & Risk Management (ETRM) sandbox and learning lab platform. Your job is to verify that:

1. The infrastructure actually works
2. The labs are technically correct
3. The learning progression makes sense
4. The content is production-relevant (not toy examples)
5. There are no gaps that would leave a learner unprepared

Be ruthless. Flag everything that is wrong, misleading, incomplete, or could confuse a learner. The goal is a platform that produces world-class energy trading technologists.

---

## SECTION 1: Infrastructure Verification

Run each of these checks and report PASS/FAIL with evidence.

### 1.1 Docker Stack Health
```bash
docker compose ps
```
**Verify:** All 10 services are running and healthy:
- [ ] etrm-mssql (Azure SQL Edge, port 1433)
- [ ] etrm-clickhouse (port 8123, 9000)
- [ ] etrm-mdm-postgres (port 5432)
- [ ] etrm-kafka (port 9092)
- [ ] etrm-zookeeper (port 2181)
- [ ] etrm-redis (port 6379)
- [ ] etrm-prometheus (port 9090)
- [ ] etrm-grafana (port 3000)
- [ ] etrm-superset (port 8088)
- [ ] etrm-localstack (port 4566)

### 1.2 MSSQL Database
```bash
# Connect via pymssql or DBeaver: localhost:1433, sa, YourStr0ngPass1, database: etrm
```
**Verify:**
- [ ] Database `etrm` exists
- [ ] Tables exist: `trade`, `trade_component`, `delivery_profile`, `curve`, `invoice`, `half_hour_intervals`
- [ ] Seed data: 5 trades, 5 trade_components, 3 delivery_profiles, 5 curves
- [ ] Views exist: `vw_trade_blotter`, `vw_counterparty_exposure`, `vw_invoice_status`, `vw_book_summary`
- [ ] `trade.counterparty_mdm_id` references MDM IDs (MDM-001, MDM-002, MDM-003) — NOT a local FK
- [ ] No `counterparty` table exists in MSSQL (it was moved to MDM Postgres)

### 1.3 ClickHouse Database
```bash
# Connect: localhost:8123, user: default, no password, database: etrm
```
**Verify:**
- [ ] Database `etrm` exists
- [ ] Tables exist: `market_data`, `mtm_curve`, `transaction_exploded`, `ppa_production`
- [ ] All tables use `ReplacingMergeTree` engine with `issue_datetime` as version column
- [ ] Seed data: `SELECT count(*) FROM etrm.market_data` returns 4000+ rows
- [ ] Seed data: `SELECT count(*) FROM etrm.transaction_exploded` returns 4000+ rows
- [ ] Views exist: `vw_pnl_by_trade`, `vw_pnl_daily`, `vw_market_prices_latest`, `vw_mtm_curve_latest`, `vw_trade_intervals_flat`
- [ ] `FINAL` keyword works: `SELECT count(*) FROM etrm.transaction_exploded` vs `SELECT count(*) FROM etrm.transaction_exploded FINAL` should return different counts for trade_id=1

### 1.4 MDM Postgres
```bash
# Connect: localhost:5432, user: mdm, password: mdmpass, database: mdm
```
**Verify:**
- [ ] Database `mdm` exists
- [ ] Tables exist: `golden_record`, `incoming_record`, `stewardship_queue`
- [ ] 3 golden records: MDM-001 (Tokyo Energy Corp), MDM-002 (AUS Grid Partners), MDM-003 (NZ Renewable Trust)
- [ ] `golden_record.mdm_id` values match `trade.counterparty_mdm_id` in MSSQL
- [ ] Credit limits are set and realistic

### 1.5 Kafka
```bash
docker exec etrm-kafka kafka-topics --list --bootstrap-server localhost:9092
```
**Verify:**
- [ ] 5 topics exist: `trade.events`, `market.prices`, `settlement.run`, `pnl.calc`, `counterparty.updated`
- [ ] `trade.events` has 3 partitions
- [ ] `counterparty.updated` has 3 partitions
- [ ] Messages can be produced and consumed

### 1.6 Superset
```bash
curl -s http://localhost:8088/api/v1/security/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin","provider":"db","refresh":true}'
```
**Verify:**
- [ ] Login succeeds (returns access_token)
- [ ] 2 database connections exist: "ETRM ClickHouse" and "ETRM MSSQL"
- [ ] 6 datasets exist (4 ClickHouse views + trade + invoice)
- [ ] 7 charts exist
- [ ] 2 dashboards exist with charts linked
- [ ] SQL Lab can query both databases

### 1.7 Grafana & Prometheus
**Verify:**
- [ ] Grafana accessible at localhost:3000 (admin/admin)
- [ ] Prometheus accessible at localhost:9090
- [ ] `up` query in Prometheus returns targets
- [ ] ClickHouse datasource configured in Grafana
- [ ] Prometheus datasource configured in Grafana

### 1.8 Cross-Database Consistency
**This is critical — verify the data relationships are intact across all 3 databases:**
- [ ] Every `counterparty_mdm_id` in MSSQL `trade` table has a matching `mdm_id` in MDM Postgres `golden_record`
- [ ] Every `trade_id` in MSSQL `trade` table has corresponding rows in ClickHouse `transaction_exploded`
- [ ] Area IDs are consistent: 1=JEPX, 2=NEM, 3=NZEM across all databases
- [ ] Currency codes are consistent: JEPX=JPY, NEM=AUD, NZEM=NZD

---

## SECTION 2: Lab Technical Accuracy

For each lab, verify the SQL queries, commands, and expected outputs are correct.

### 2.1 Lab 1 — Databases
- [ ] All SQL queries in the lab execute without errors
- [ ] Expected row counts match actual seed data
- [ ] The `counterparty_mdm_id` explanation is correct (not a local FK, references MDM Postgres)
- [ ] ClickHouse `FINAL` demonstration works (shows different row counts with/without)
- [ ] `argMax` explanation is technically correct
- [ ] DBeaver connection strings are correct for all 3 databases

### 2.2 Lab 2 — Kafka
- [ ] All `kafka-topics` and `kafka-console-*` commands work
- [ ] Topic descriptions match docker-compose configuration
- [ ] Consumer lag explanation is correct
- [ ] The test message JSON is valid and consumable

### 2.3 Lab 3 — Superset
- [ ] All SQL queries used in chart building execute correctly
- [ ] Dataset names match what's provisioned
- [ ] Chart types mentioned (bar, pie, big number, line) are available in Superset 3.1
- [ ] Dashboard filter instructions are accurate for Superset 3.1 UI

### 2.4 Lab 4 — P&L Investigation
- [ ] P&L formula is correct: `(valuation_price - contracted_price) × quantity`
- [ ] The COALESCE fallback pattern is correct: `COALESCE(settle_price, mtm_price)`
- [ ] Time-travel queries using `issue_datetime` work correctly
- [ ] The investigation flow is realistic (would actually find the root cause)

### 2.5 Lab 5 — Terraform
- [ ] Terraform files exist at `infra/terraform/`
- [ ] `terraform init` and `terraform plan` work with LocalStack
- [ ] S3 bucket names match documentation

### 2.6 Lab 6 — Monitoring
- [ ] Prometheus queries are valid PromQL
- [ ] Grafana datasource provisioning files exist and are correct
- [ ] Alert rule syntax is correct for Grafana 10.x

### 2.7 Lab 7 — CI/CD
- [ ] GitHub Actions workflow syntax is valid YAML
- [ ] Job dependencies (`needs:`) are correct
- [ ] The anti-pattern check (no UPDATE/DELETE on ClickHouse) is a real best practice

### 2.8 Lab 8 — Networking
- [ ] CIDR calculations are mathematically correct
- [ ] Docker network commands work
- [ ] VPC subnet design follows AWS best practices
- [ ] Security group rules are sensible (no overly permissive rules)

### 2.9 Lab 9 — MDM
- [ ] Match/merge score thresholds are documented: >=90 AUTO_MERGE, 60-89 QUEUE, <60 NEW
- [ ] SQL for inserting incoming records and stewardship queue entries is correct
- [ ] Kafka `counterparty.updated` event structure is documented
- [ ] The MDM-to-ETRM flow explanation is accurate

### 2.10 Lab 10 — Go Trade Service
- [ ] Go code compiles (`go build ./...`)
- [ ] Trade explosion algorithm produces correct interval counts:
  - STANDARD (Feb 1-28): 28 × 48 = 1,344 intervals
  - CONSTANT (Feb 1-28, weekdays 07-17): 20 weekdays × 20 slots = 400 intervals
  - VARIABLE (Feb 1-28, 06-22): 28 × 32 = 896 intervals
- [ ] Test assertions are mathematically correct
- [ ] The dual-write problem (MSSQL + ClickHouse) is acknowledged and discussed
- [ ] Dockerfile follows multi-stage build best practices

### 2.11 Lab 11 — Incident Response
- [ ] The scenario is realistic (traders do report P&L discrepancies)
- [ ] The triage steps would actually find the root cause
- [ ] The ClickHouse correction pattern (insert with newer issue_datetime) is correct
- [ ] The postmortem template follows industry standards (Google SRE format)
- [ ] The 3-sigma anomaly detection query is statistically sound

### 2.12 Lab 12 — Performance Tuning
- [ ] `system.query_log` queries are valid ClickHouse SQL
- [ ] Projection syntax is correct for ClickHouse 24.x
- [ ] MSSQL index syntax is correct
- [ ] The batch vs row-by-row insert comparison is fair
- [ ] Materialized view syntax with `AggregatingMergeTree` is correct
- [ ] The `avgState` / `avgMerge` pattern is correctly used

### 2.13 Lab 13 — Settlement & Invoicing
- [ ] Settlement calculation: MWh = MW × 0.5 (for 30-min intervals) is correct
- [ ] Invoice matching tolerance logic is correct
- [ ] The PHYSICAL vs FINANCIAL distinction is accurately explained
- [ ] Imbalance charge concept is correct for electricity markets

### 2.14 Lab 14 — Kafka Streaming Pipeline
- [ ] Python producer code uses `kafka-python` correctly
- [ ] Python consumer code uses `clickhouse-connect` correctly
- [ ] VWAP formula is correct: `sum(price × volume) / sum(volume)`
- [ ] The z-score anomaly detection window function is valid ClickHouse SQL
- [ ] Consumer group configuration is correct

### 2.15 Lab 15 — System Design
- [ ] Architecture diagram is complete and consistent
- [ ] Capacity calculations are realistic for an APAC energy desk
- [ ] Failure mode analysis covers all critical components
- [ ] Security architecture follows defense-in-depth principles
- [ ] The technology justification table has no factual errors

---

## SECTION 3: Learning Progression Audit

### 3.1 Skill Ramp
- [ ] Labs 1-3 require no prior knowledge of ETRM systems
- [ ] Each lab builds on skills from previous labs (no circular dependencies)
- [ ] The jump from Lab 9 → Lab 10 is not too steep (Go service from scratch)
- [ ] Lab 15 (system design) is a genuine capstone that tests all prior knowledge

### 3.2 Domain Knowledge
- [ ] ETRM concepts (P&L, MTM, settlement, products) are explained before they're needed
- [ ] APAC market specifics (JEPX, NEM, NZEM) are accurate
- [ ] The dual-database rationale (MSSQL for ACID, ClickHouse for analytics) is clearly explained
- [ ] The MDM motivation (why extract counterparty from MSSQL) is convincing

### 3.3 Interview Readiness
- [ ] The "Questions to Be Able to Answer" section covers real interview questions
- [ ] Each question has an answer discoverable within the labs
- [ ] The skill progression map (Junior → Staff/Principal) is realistic
- [ ] Lab 15's "hard questions" are the kind actually asked in trading tech interviews

### 3.4 Gaps Analysis
Flag any of these that are missing or inadequately covered:
- [ ] Error handling patterns (what happens when things go wrong?)
- [ ] Testing strategy (unit, integration, end-to-end)
- [ ] Deployment (how does this go to production?)
- [ ] Observability (beyond basic Prometheus metrics)
- [ ] Data governance / lineage (where did this number come from?)
- [ ] Disaster recovery (backup, restore, RTO/RPO)
- [ ] Multi-tenancy / multi-book isolation
- [ ] Regulatory compliance specifics (AEMO, JEPX, NZ EA)
- [ ] Real market data API integration (vs synthetic only)
- [ ] Performance under load (what happens at 100x scale?)

---

## SECTION 4: Code & Configuration Quality

### 4.1 docker-compose.yml
- [ ] All services have healthchecks
- [ ] All services have `restart: unless-stopped`
- [ ] No hardcoded secrets in the compose file (uses .env or defaults)
- [ ] Platform specifications are correct for ARM64 (Apple Silicon)
- [ ] Volume mounts are correct
- [ ] Service dependencies (`depends_on`) are sensible

### 4.2 SQL Scripts
- [ ] `init_mssql.sql` — DDL is valid MSSQL/Azure SQL Edge syntax
- [ ] `init_clickhouse.sql` — DDL is valid ClickHouse 24.x syntax
- [ ] `init_mdm_postgres.sql` — DDL is valid PostgreSQL 16 syntax
- [ ] `powerbi_views_mssql.sql` — views are valid and produce correct results
- [ ] `powerbi_views_clickhouse.sql` — views are valid and produce correct results
- [ ] All seed data is consistent across databases (same trade IDs, same counterparties)

### 4.3 Provisioning Scripts
- [ ] `superset_provision.py` — creates datasets, charts, dashboards without errors
- [ ] The script is idempotent (can be run multiple times safely)
- [ ] Error handling is adequate (doesn't silently fail)

### 4.4 Makefile
- [ ] All make targets work
- [ ] `make check-health` verifies all services
- [ ] `make wipe` cleanly removes volumes
- [ ] Commands use correct Docker CLI syntax

---

## SECTION 5: Documentation Quality

### 5.1 Accuracy
- [ ] All file paths referenced in docs actually exist
- [ ] All port numbers in docs match docker-compose.yml
- [ ] All credentials in docs match .env / docker-compose.yml
- [ ] All SQL queries in docs execute without errors

### 5.2 Clarity
- [ ] Each lab states prerequisites, time estimate, and learning goal
- [ ] Each lab has a checkpoint section for self-assessment
- [ ] Technical terms are explained on first use
- [ ] The "why" is explained, not just the "what"

### 5.3 Completeness
- [ ] `learning_roadmap.md` covers all 15 labs
- [ ] `IMPLEMENTATION_PLAN.md` file tree matches actual project structure
- [ ] Every database, table, view, and Kafka topic is documented somewhere
- [ ] The Makefile has a help target that lists all commands

---

## SECTION 6: Severity Ratings

For each finding, rate as:
- **CRITICAL** — Blocks a learner from completing a lab (broken query, wrong port, missing table)
- **HIGH** — Misleads a learner or teaches incorrect information
- **MEDIUM** — Confusing but workaroundable (unclear instructions, missing context)
- **LOW** — Polish issue (typo, formatting, could be better explained)
- **ENHANCEMENT** — Not wrong, but could be improved

---

## OUTPUT FORMAT

Produce your audit report in this format:

```markdown
# ETRM Sandbox Audit Report
**Date:** [date]
**Auditor:** [model/version]
**Repository:** [path]

## Executive Summary
[2-3 sentences: overall quality, critical issues found, recommendation]

## Infrastructure: X/10 checks passed
[List of PASS/FAIL with evidence]

## Lab Accuracy: X/15 labs verified
[Findings per lab, sorted by severity]

## Learning Progression: [PASS/NEEDS WORK]
[Assessment of skill ramp, gaps, interview readiness]

## Code Quality: [PASS/NEEDS WORK]
[Findings sorted by severity]

## Documentation: [PASS/NEEDS WORK]
[Findings sorted by severity]

## Critical Issues (must fix)
[Numbered list]

## High Priority Issues
[Numbered list]

## Enhancement Suggestions
[Numbered list]

## Overall Rating: [1-10]
[Justification]
```

## PROMPT END

# Lab 9 — MDM: Golden Records, Match/Merge, Stewardship

**Prereqs:** Lab 1 complete (databases running). Docker stack running (`make up`). DBeaver installed.
**Time:** 2-3 hours (Parts A-H: 90 min core, Parts I-L: 60 min advanced)
**Goal:** Understand Master Data Management deeply enough to design, operate, and defend an MDM system in an interview or on the job. You'll work with real seed data, learn survivorship rules, understand data quality dimensions, and trace how MDM integrates with every other system in the stack. The advanced sections (I-L) take you from "understands MDM" to "can architect an MDM system from scratch and defend every design decision."

---

## Why This Matters

In production, counterparty data comes from multiple source systems — the trading desk, broker feeds, invoice systems, risk platforms. Each system has its own name for the same entity:

```
Trading Desk:    "Tokyo Energy Corp"
Broker Feed:     "TEC"
Invoice System:  "Tokyo Energy Corporation Ltd."
Risk System:     "AUS Grid Ptrs"
```

Without MDM, you'd have duplicate counterparty records with conflicting credit limits, creating:
- **Regulatory risk** — reporting the wrong exposure to AEMO or JEPX
- **Credit risk** — booking a trade against a stale limit, then discovering the counterparty is over-limit
- **Operational risk** — sending an invoice to the wrong legal entity name

MDM solves this by maintaining a single **golden record** — the canonical, trusted version of each counterparty. The match/merge engine links incoming records automatically when confidence is high, and routes ambiguous cases to a **stewardship queue** for human review.

**The mental model:** MDM is not a database. It is a *system of trust*. Every piece of data has a lineage (where it came from), a confidence score (how much we trust it), and a survivorship rule (which value wins when sources disagree).

---

## Part A — Explore the MDM Database (10 min)

Connect in DBeaver: `localhost:5432`, user `mdm`, password `mdmpass`, database `mdm`.

### Task A1: Browse the golden records

```sql
SELECT mdm_id, canonical_name, short_code, credit_limit, currency, is_active, data_steward
FROM golden_record
ORDER BY mdm_id;
```

**Expected:** 3 rows:

| mdm_id | canonical_name | short_code | credit_limit | currency | data_steward |
|--------|---------------|------------|-------------|----------|--------------|
| MDM-001 | Tokyo Energy Corp | TEC | 5,000,000 | JPY | kenji.tanaka |
| MDM-002 | AUS Grid Partners | AGP | 3,000,000 | AUD | sarah.chen |
| MDM-003 | NZ Renewable Trust | NZRT | 2,000,000 | NZD | sarah.chen |

These are the **golden records** — the single source of truth for each counterparty. Notice `data_steward` — every golden record has an owner who is accountable for its accuracy.

### Task A2: Understand the 3-table schema

```sql
-- What tables exist in the MDM database?
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public'
ORDER BY table_name;
```

**Expected:** `golden_record`, `incoming_record`, `stewardship_queue`

This is the classic MDM schema pattern:

| Table | Purpose | Analogy |
|-------|---------|---------|
| `golden_record` | The truth — canonical entities | The "master copy" |
| `incoming_record` | Every record from every source system | The "inbox" |
| `stewardship_queue` | Conflicts that need human judgment | The "exception queue" |

**Key insight:** The golden record is never written to directly by source systems. It is only updated through the match/merge engine or by a data steward resolving a conflict. This is what makes it *trustworthy*.

### Task A3: Explore the incoming records

The seed data includes 6 incoming records from different source systems. Query them:

```sql
SELECT
    record_id,
    source_system,
    source_id,
    raw_name,
    credit_limit,
    match_status,
    matched_mdm_id,
    match_score,
    received_at
FROM incoming_record
ORDER BY record_id;
```

**Study the output carefully:**

| source_system | raw_name | match_status | match_score | Why? |
|--------------|----------|-------------|-------------|------|
| BROKER_FEED | TEC | AUTO_MERGED | 92.5 | Exact short_code match |
| INVOICE_SYSTEM | Tokyo Energy Corporation Ltd. | QUEUED | 75.0 | Partial name match, credit limit differs |
| TRADING_DESK | NZ Renewable Trust | AUTO_MERGED | 98.0 | Exact name match |
| BROKER_FEED | Kansai Power Trading GK | NEW | 12.0 | No match — unknown entity |
| RISK_SYSTEM | AUS Grid Ptrs | QUEUED | 68.0 | Abbreviated name, credit limit differs |
| BROKER_FEED | AGP | AUTO_MERGED | 95.0 | Exact short_code match |

**Questions to answer:**
- Why did "TEC" get a 92.5 score but not 100? (Answer: short_code matched exactly, but `credit_limit` differed from golden — 4.5M vs 5M — so the score was penalized)
- Why is "Kansai Power Trading GK" scored at 12.0? (Answer: no name, short_code, or fuzzy match to any existing golden record)
- What's the difference between QUEUED and NEW? (Answer: QUEUED means we found a *probable* match but aren't sure enough to auto-merge. NEW means no match was found at all — this might be a brand new counterparty)

### Task A4: Check the stewardship queue

```sql
SELECT
    sq.queue_id,
    sq.status,
    sq.conflict_fields::text,
    ir.source_system,
    ir.raw_name,
    ir.credit_limit AS incoming_credit_limit,
    gr.canonical_name,
    gr.credit_limit AS golden_credit_limit
FROM stewardship_queue sq
JOIN incoming_record ir ON ir.record_id = sq.record_a_id
LEFT JOIN golden_record gr ON gr.mdm_id = ir.matched_mdm_id
WHERE sq.status = 'OPEN';
```

**Expected:** 2 open conflicts:
1. "Tokyo Energy Corporation Ltd." vs "Tokyo Energy Corp" — credit limit 6M vs 5M
2. "AUS Grid Ptrs" vs "AUS Grid Partners" — credit limit 3.2M vs 3M

These are real decisions a data steward makes every day. Don't skip this — understanding *why* conflicts arise is the heart of MDM.

---

## Part B — Understand the MDM-to-ETRM Link (10 min)

### Task B1: See how MSSQL trades reference MDM

Open a second DBeaver connection to MSSQL (`localhost:1433`, `sa`, `YourStr0ngPass1`, database `etrm`):

```sql
-- Trades reference counterparties by MDM ID, not by a local counterparty table
SELECT
    t.unique_id AS trade_ref,
    t.counterparty_mdm_id,
    tc.area_id,
    CASE tc.area_id WHEN 1 THEN 'JEPX' WHEN 2 THEN 'NEM' WHEN 3 THEN 'NZEM' END AS market,
    tc.quantity,
    tc.price,
    tc.price_denominator AS currency
FROM trade t
JOIN trade_component tc ON tc.trade_id = t.trade_id
WHERE t.is_active = 1
ORDER BY t.counterparty_mdm_id;
```

**Key observation:** The `counterparty_mdm_id` column (e.g. `MDM-001`) is a string reference to `golden_record.mdm_id` in MDM Postgres. There is no foreign key across databases — the link is maintained by convention and the MDM service.

**Why no foreign key?** Because MSSQL and Postgres are different databases on different servers. Cross-database foreign keys don't exist. Instead, the MDM service publishes `counterparty.updated` Kafka events, and consuming services (like the trade service) maintain a local cache (Redis) that they validate against.

### Task B2: Cross-database lookup (manual join)

Do this manually to understand the cross-system data flow:

1. From the MSSQL query above, note which `counterparty_mdm_id` values appear
2. Switch to MDM Postgres and look them up:

```sql
-- MDM Postgres: get counterparty details for the MDM IDs you found
SELECT mdm_id, canonical_name, short_code, credit_limit, currency
FROM golden_record
WHERE mdm_id IN ('MDM-001', 'MDM-002', 'MDM-003');
```

3. Mentally combine: "TRADE-JP-001 is with MDM-001 (Tokyo Energy Corp, credit limit ¥5M)"

**Why this matters:** In production, the Go trade service does this lookup via the MDM REST API (`GET /counterparties/MDM-001`) or reads from a Redis cache populated by `counterparty.updated` Kafka events. You're doing it manually to understand the data flow.

### Task B3: Check credit exposure vs MDM limits

```sql
-- MSSQL: exposure per counterparty
SELECT
    t.counterparty_mdm_id,
    COUNT(DISTINCT t.trade_id) AS open_trades,
    SUM(tc.quantity * tc.price) AS total_notional
FROM trade t
JOIN trade_component tc ON tc.trade_id = t.trade_id
WHERE t.is_active = 1
GROUP BY t.counterparty_mdm_id
ORDER BY total_notional DESC;
```

Compare against the credit limits from Task B2.

**Questions:**
- Is any counterparty over their credit limit?
- What is the utilisation percentage for each? (`total_notional / credit_limit * 100`)
- If MDM-001's credit limit was lowered to ¥1,000,000 via the MDM service, what would happen to existing trades? (Answer: existing trades stay — credit check only blocks *new* trades)

---

## Part C — The Match/Merge Engine: How It Actually Works (15 min)

This is the brain of any MDM system. Understanding this deeply is what separates someone who *uses* MDM from someone who can *design* one.

### The Three Routing Outcomes

Every incoming record goes through the match engine, which produces a **confidence score** (0-100):

```
Score >= 90  →  AUTO_MERGE    (high confidence — link to golden record automatically)
Score 60-89  →  QUEUE         (ambiguous — route to stewardship for human review)
Score < 60   →  NEW           (no match — probably a new entity, create new golden record)
```

### How Scoring Works

The match engine compares an incoming record against ALL golden records using multiple signals:

| Signal | Weight | Example |
|--------|--------|---------|
| Exact short_code match | 60 points | "TEC" = "TEC" → +60 |
| Exact canonical_name match | 50 points | "NZ Renewable Trust" = "NZ Renewable Trust" → +50 |
| Fuzzy name match (>80% similarity) | 30 points | "Tokyo Energy Corporation Ltd." ≈ "Tokyo Energy Corp" → +30 |
| Fuzzy name match (60-80% similarity) | 15 points | "AUS Grid Ptrs" ≈ "AUS Grid Partners" → +15 |
| Credit limit within 10% | 10 points | 4.5M vs 5M = 10% diff → +10 |
| Credit limit differs > 10% | -5 points | 6M vs 5M = 20% diff → -5 |
| Same currency | 5 points | JPY = JPY → +5 |

**Exercise:** Manually calculate the score for each seed incoming record:

```sql
-- Get the data you need for manual scoring
SELECT
    ir.source_id,
    ir.raw_name,
    ir.credit_limit AS incoming_limit,
    ir.match_score AS engine_score,
    gr.canonical_name AS golden_name,
    gr.short_code,
    gr.credit_limit AS golden_limit
FROM incoming_record ir
LEFT JOIN golden_record gr ON gr.mdm_id = ir.matched_mdm_id
ORDER BY ir.record_id;
```

Pick "BRK-8821" (raw_name = "TEC") and trace through:
- short_code match "TEC" = "TEC" → +60
- Name "TEC" fuzzy match "Tokyo Energy Corp" → weak, maybe +15
- Credit limit 4.5M vs 5M = 10% diff → +10
- Currency: not provided in incoming → +0
- Total: ~85-92 → that's why it scored 92.5 (engine has additional sub-signals)

### Task C1: Analyze match distribution

```sql
-- What percentage of incoming records auto-merged vs needed review?
SELECT
    match_status,
    COUNT(*) AS count,
    ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM incoming_record), 1) AS pct
FROM incoming_record
GROUP BY match_status
ORDER BY count DESC;
```

**Expected:**
- AUTO_MERGED: 3 (50%) — the easy cases
- QUEUED: 2 (33%) — need human judgment
- NEW: 1 (17%) — unknown entity

**Industry benchmark:** A well-tuned match engine auto-merges 70-85% of records. Below 60% means your rules are too conservative (too much steward work). Above 90% means your rules are too aggressive (risk of false merges).

### Task C2: Understand false merges vs false separations

This is the critical trade-off in every MDM system:

| Error Type | What Happens | Business Impact | Example |
|-----------|-------------|----------------|---------|
| **False merge** | Two different entities linked to same golden record | Trade booked against wrong counterparty. Wrong credit limit applied. Regulatory breach. | "Tokyo Power" merged with "Tokyo Energy Corp" — they're different companies |
| **False separation** | Same entity stored as two golden records | Duplicate exposure. Credit limit split across two records. Incorrect netting for settlement. | "AUS Grid Partners" and "AUS Grid Ptrs" kept as separate records |

**Question:** Which is worse? (Answer: False merges are *always* worse in a regulated trading environment. You can fix a false separation by merging later. A false merge can cause trades booked against wrong entities — and unwinding that is a nightmare. This is why the threshold for AUTO_MERGE is high.)

---

## Part D — Survivorship Rules: Which Value Wins? (15 min)

When two records describe the same entity but disagree on field values, **survivorship rules** decide which value becomes the golden record. This is what makes MDM an *art*, not just a database.

### The Five Survivorship Strategies

| Strategy | Rule | When to Use | Example |
|----------|------|-------------|---------|
| **Source priority** | Always trust Source A over Source B | When one system is the official owner | Credit team's system > broker feed for credit limits |
| **Most recent** | Use the newest value | When freshness matters | Address, phone number, contact person |
| **Most frequent** | Use the value that appears most often across sources | When you have many sources | Legal entity name (3 out of 5 systems agree) |
| **Longest** | Use the most complete value | When systems truncate data | "Tokyo Energy Corporation Ltd." > "TEC" for legal name |
| **Manual** | Data steward decides | When the conflict is complex or high-stakes | Credit limit changes that exceed a threshold |

### Task D1: Apply survivorship rules to real conflicts

Look at the two open stewardship conflicts:

```sql
SELECT
    sq.queue_id,
    sq.conflict_fields,
    ir.source_system,
    ir.raw_name,
    ir.credit_limit AS incoming_limit,
    gr.canonical_name AS golden_name,
    gr.credit_limit AS golden_limit,
    gr.data_steward
FROM stewardship_queue sq
JOIN incoming_record ir ON ir.record_id = sq.record_a_id
LEFT JOIN golden_record gr ON gr.mdm_id = ir.matched_mdm_id
WHERE sq.status = 'OPEN';
```

**Conflict 1:** "Tokyo Energy Corporation Ltd." (Invoice System, ¥6M) vs "Tokyo Energy Corp" (golden, ¥5M)

Apply survivorship rules:
- **Name:** Use "longest" strategy → "Tokyo Energy Corporation Ltd." is more complete... but wait — is this the actual legal name? The invoice system might have the official registered name. As steward, you'd verify with the legal team before changing.
- **Credit limit:** Use "source priority" strategy → does the invoice system have authority to set credit limits? Probably not — the credit team does. You'd keep ¥5M unless the credit team confirms the increase.

**Conflict 2:** "AUS Grid Ptrs" (Risk System, A$3.2M) vs "AUS Grid Partners" (golden, A$3M)

Apply survivorship rules:
- **Name:** "AUS Grid Ptrs" is clearly an abbreviation. Keep the golden record name "AUS Grid Partners" (longest strategy).
- **Credit limit:** The risk system says A$3.2M. Risk systems are often authoritative for credit. As steward, you'd check: did the credit team actually approve a A$200K increase? If yes, update. If the risk system is just pulling from a stale spreadsheet, reject.

### Task D2: Resolve Conflict 1

```sql
-- Steward decision: keep golden name (it's the registered short form), reject credit increase
UPDATE stewardship_queue
SET
    status = 'RESOLVED',
    resolved_by = 'kenji.tanaka',
    resolution = '{"decision": "keep_golden_name", "credit_limit": 5000000, "rationale": "Credit team has not approved increase to 6M. Invoice system is not authoritative for credit limits. Name kept as registered short form."}',
    resolved_at = NOW()
WHERE queue_id = (SELECT queue_id FROM stewardship_queue sq
                  JOIN incoming_record ir ON ir.record_id = sq.record_a_id
                  WHERE ir.source_id = 'INV-2025-441' LIMIT 1);

-- Update incoming record status
UPDATE incoming_record
SET match_status = 'RESOLVED'
WHERE source_id = 'INV-2025-441';
```

### Task D3: Resolve Conflict 2

```sql
-- Steward decision: keep golden name, accept credit increase (risk system is authoritative)
UPDATE stewardship_queue
SET
    status = 'RESOLVED',
    resolved_by = 'sarah.chen',
    resolution = '{"decision": "update_credit", "credit_limit": 3200000, "rationale": "Risk system confirmed credit increase approved by credit committee 2025-01-28. Name kept as full form."}',
    resolved_at = NOW()
WHERE queue_id = (SELECT queue_id FROM stewardship_queue sq
                  JOIN incoming_record ir ON ir.record_id = sq.record_a_id
                  WHERE ir.source_id = 'RSK-AU-007' LIMIT 1);

-- Update the golden record with the approved credit increase
UPDATE golden_record
SET credit_limit = 3200000, updated_at = NOW()
WHERE mdm_id = 'MDM-002';

-- Update incoming record status
UPDATE incoming_record
SET match_status = 'RESOLVED'
WHERE source_id = 'RSK-AU-007';
```

Verify everything:
```sql
-- All conflicts should be resolved
SELECT queue_id, status, resolved_by, resolution FROM stewardship_queue;

-- Golden record should reflect the credit increase for MDM-002
SELECT mdm_id, canonical_name, credit_limit, updated_at FROM golden_record ORDER BY mdm_id;

-- All incoming records should be in a terminal state
SELECT source_id, raw_name, match_status, match_score FROM incoming_record ORDER BY record_id;
```

### Task D4: Create a new golden record from the unmatched entity

"Kansai Power Trading GK" (BRK-9102) matched nothing. After verification, the steward creates a new golden record:

```sql
-- Create a new golden record for the verified new counterparty
INSERT INTO golden_record (mdm_id, canonical_name, short_code, credit_limit, currency, data_steward)
VALUES ('MDM-004', 'Kansai Power Trading GK', 'KPTG', 1500000, 'JPY', 'kenji.tanaka');

-- Link the incoming record to the new golden record
UPDATE incoming_record
SET match_status = 'MERGED_NEW', matched_mdm_id = 'MDM-004', match_score = 100.0
WHERE source_id = 'BRK-9102';
```

Verify:
```sql
SELECT mdm_id, canonical_name, short_code, credit_limit FROM golden_record ORDER BY mdm_id;
```

**Expected:** 4 golden records now. This is the full MDM lifecycle: ingest → match → merge OR queue → steward → resolve → golden record.

---

## Part E — Data Quality Dimensions (10 min)

MDM experts think about data quality across 6 dimensions. This framework comes up in every MDM interview and architecture review.

### The Six Dimensions

| Dimension | Definition | How to Measure | Example in Our Data |
|-----------|-----------|---------------|---------------------|
| **Completeness** | Are all required fields populated? | % of records with non-null values | Does every golden record have `short_code`? |
| **Accuracy** | Are the values correct? | Compare against authoritative source | Is MDM-001's credit limit actually ¥5M? |
| **Consistency** | Do the same values appear the same way across systems? | Cross-system comparison | Is "Tokyo Energy Corp" spelled the same everywhere? |
| **Timeliness** | Is the data current? | Age of last update | When was `updated_at` last refreshed? |
| **Uniqueness** | Is each entity represented exactly once? | Duplicate detection | No two golden records for the same real-world company |
| **Validity** | Do values conform to business rules? | Rule-based checks | Is `credit_limit` positive? Is `currency` a valid ISO code? |

### Task E1: Measure data quality across your golden records

```sql
-- Completeness: check for nulls in critical fields
SELECT
    COUNT(*) AS total_records,
    COUNT(canonical_name) AS has_name,
    COUNT(short_code) AS has_short_code,
    COUNT(credit_limit) AS has_credit_limit,
    COUNT(data_steward) AS has_steward,
    ROUND(COUNT(short_code) * 100.0 / COUNT(*), 1) AS short_code_completeness_pct,
    ROUND(COUNT(data_steward) * 100.0 / COUNT(*), 1) AS steward_completeness_pct
FROM golden_record
WHERE is_active = true;
```

### Task E2: Measure consistency across sources

```sql
-- How many different names does each golden record have across source systems?
SELECT
    gr.mdm_id,
    gr.canonical_name AS golden_name,
    COUNT(DISTINCT ir.raw_name) AS source_name_variants,
    STRING_AGG(DISTINCT ir.raw_name, ' | ') AS all_names_seen
FROM golden_record gr
LEFT JOIN incoming_record ir ON ir.matched_mdm_id = gr.mdm_id
GROUP BY gr.mdm_id, gr.canonical_name
ORDER BY source_name_variants DESC;
```

**Key insight:** MDM-001 has the most name variants (TEC, Tokyo Energy Corporation Ltd.). This is normal for large counterparties — every system stores their name slightly differently. The golden record absorbs this chaos and presents one clean name.

### Task E3: Measure timeliness

```sql
-- Which golden records haven't been updated recently?
SELECT
    mdm_id,
    canonical_name,
    updated_at,
    NOW() - updated_at AS age,
    CASE
        WHEN NOW() - updated_at < INTERVAL '7 days' THEN 'FRESH'
        WHEN NOW() - updated_at < INTERVAL '30 days' THEN 'AGING'
        ELSE 'STALE'
    END AS freshness
FROM golden_record
ORDER BY updated_at ASC;
```

**In production:** Stale golden records are a risk. If a counterparty's credit limit changed 6 months ago and MDM doesn't know, you're trading against outdated limits.

---

## Part F — Verify Kafka Integration (5 min)

### Task F1: Confirm the counterparty.updated topic exists

```bash
docker exec etrm-kafka kafka-topics \
  --describe --topic counterparty.updated \
  --bootstrap-server localhost:9092
```

**Expected:** Topic exists with 3 partitions, replication factor 1.

### Task F2: Simulate a counterparty update event

After resolving a stewardship conflict and updating a golden record, the MDM service publishes an event so downstream systems (trade service, risk engine) refresh their caches:

```bash
echo '{"event_type":"counterparty.updated","mdm_id":"MDM-002","canonical_name":"AUS Grid Partners","short_code":"AGP","credit_limit":3200000,"currency":"AUD","is_active":true,"updated_by":"sarah.chen","reason":"credit_increase_approved"}' | \
docker exec -i etrm-kafka kafka-console-producer \
  --bootstrap-server localhost:9092 \
  --topic counterparty.updated
```

### Task F3: Consume it back

```bash
docker exec etrm-kafka kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic counterparty.updated \
  --from-beginning \
  --max-messages 5
```

**Expected:** Your event appears. In production, the trade service's Kafka consumer picks this up and updates its Redis cache. The next credit check against MDM-002 uses the new A$3.2M limit.

---

## Part G — MDM Architecture Patterns (10 min)

Understanding these patterns is what makes you sound like an expert in interviews.

### The Three MDM Styles

| Style | How It Works | Pros | Cons | Our System |
|-------|-------------|------|------|------------|
| **Registry** | MDM stores only IDs + links. Data stays in source systems. | Low cost, easy adoption | No single golden record — must query sources at read time | |
| **Consolidation** | MDM pulls data from sources into a read-only golden copy. Sources are not updated. | Golden record exists, sources unchanged | Sources can drift from golden. Two sources of "truth" | |
| **Coexistence** | MDM maintains golden record AND pushes changes back to sources via events. Sources stay in sync. | True single source of truth. All systems consistent. | Most complex. Requires Kafka/event infrastructure. | **This one** |

**Our sandbox uses the Coexistence style:** Golden records live in MDM Postgres. When a steward resolves a conflict, the MDM service publishes a `counterparty.updated` Kafka event. The trade service consumes it and updates its Redis cache. All systems converge on the same data.

### Task G1: Trace the full MDM data flow

Draw this on paper or think it through:

```
Source System (Broker Feed)
    ↓ POST /counterparties/ingest
MDM Service (Go)
    ↓ Match/Merge Engine
    ├── Score >= 90 → AUTO_MERGE → Update golden_record
    ├── Score 60-89 → QUEUE → stewardship_queue → Steward resolves → Update golden_record
    └── Score < 60  → NEW → Steward verifies → INSERT golden_record
    ↓
golden_record updated
    ↓
MDM Service publishes Kafka event (counterparty.updated)
    ↓
Trade Service consumes event → updates Redis cache
    ↓
Next trade booking uses updated credit limit from Redis
```

### Task G2: Think about failure modes

Answer these questions:

1. **The MDM service goes down.** Can the ETRM trade service still book new trades?
   - Yes, if Redis cache has counterparty data. But credit limits won't update until MDM comes back.

2. **A steward accidentally merges two different companies.** How do you undo it?
   - You can't un-merge easily — this is why false merges are worse than false separations. In production, you'd: (a) split the golden record back into two, (b) reassign all trades to the correct entity, (c) publish correction events.

3. **A source system sends 500 records in a bulk import.** What happens?
   - Each record goes through the match engine. High-confidence matches auto-merge. Ambiguous ones queue. The steward works through the queue over days. This is normal during M&A or system migrations.

---

## Part H — Hierarchy & Relationship Modeling (15 min)

Real MDM systems don't just store flat counterparty records. They model **hierarchies** (parent/subsidiary relationships) and **cross-references** (the same entity known by different IDs in different systems). This is what separates a production MDM from a simple lookup table.

### Why Hierarchies Matter in Trading

Consider: "Tokyo Energy Corp" (MDM-001) is a subsidiary of "Tokyo Energy Holdings Group." If the parent has a group-wide credit limit of ¥20M, and MDM-001 has ¥5M, you need to check BOTH limits before booking a trade — the subsidiary limit AND the group aggregate exposure.

Without hierarchy modeling, you'd never catch that MDM-001, MDM-005 (another subsidiary), and MDM-009 (yet another) are all part of the same group and collectively exceed the group limit.

### Task H1: Add hierarchy support to the schema

```sql
-- Add parent relationship to golden_record
ALTER TABLE golden_record
ADD COLUMN parent_mdm_id VARCHAR(20) DEFAULT NULL,
ADD COLUMN hierarchy_level VARCHAR(20) DEFAULT 'OPERATING_ENTITY';

-- hierarchy_level values:
--   ULTIMATE_PARENT — top of the tree (e.g., "Tokyo Energy Holdings Group")
--   INTERMEDIATE    — middle tier (e.g., regional holding company)
--   OPERATING_ENTITY — leaf node, the entity you actually trade with (default)

COMMENT ON COLUMN golden_record.parent_mdm_id IS
  'References another golden_record.mdm_id. NULL means this is a top-level entity.';
```

### Task H2: Create a group hierarchy

```sql
-- Create the parent entity
INSERT INTO golden_record (mdm_id, canonical_name, short_code, credit_limit, currency, data_steward, hierarchy_level)
VALUES ('MDM-GRP-001', 'Tokyo Energy Holdings Group', 'TEHG', 20000000, 'JPY', 'kenji.tanaka', 'ULTIMATE_PARENT');

-- Link MDM-001 to its parent
UPDATE golden_record
SET parent_mdm_id = 'MDM-GRP-001', hierarchy_level = 'OPERATING_ENTITY'
WHERE mdm_id = 'MDM-001';
```

### Task H3: Write a group exposure query

This is the query a credit risk system runs before every trade booking:

```sql
-- Get total exposure for the entire Tokyo Energy group
WITH group_entities AS (
    -- All entities in the same group as a given MDM ID
    SELECT mdm_id FROM golden_record
    WHERE mdm_id = 'MDM-001'                    -- the entity itself
       OR mdm_id = (SELECT parent_mdm_id FROM golden_record WHERE mdm_id = 'MDM-001')  -- parent
       OR parent_mdm_id = (SELECT parent_mdm_id FROM golden_record WHERE mdm_id = 'MDM-001')  -- siblings
)
SELECT
    g.mdm_id,
    g.canonical_name,
    g.credit_limit,
    g.hierarchy_level,
    g.parent_mdm_id
FROM golden_record g
WHERE g.mdm_id IN (SELECT mdm_id FROM group_entities)
ORDER BY g.hierarchy_level, g.mdm_id;
```

**Key insight:** In production, a recursive CTE handles arbitrary depth. In energy trading, hierarchies are typically 2-3 levels deep: holding company → regional entity → trading desk.

### Task H4: Add cross-references

Cross-references track how each external system identifies the same entity:

```sql
-- Create a cross-reference table
CREATE TABLE IF NOT EXISTS counterparty_xref (
    xref_id         SERIAL PRIMARY KEY,
    mdm_id          VARCHAR(20) NOT NULL REFERENCES golden_record(mdm_id),
    source_system   VARCHAR(50) NOT NULL,
    source_id       VARCHAR(100) NOT NULL,
    source_name     VARCHAR(200),
    is_primary      BOOLEAN DEFAULT false,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(source_system, source_id)
);

COMMENT ON TABLE counterparty_xref IS
  'Maps external system IDs to golden record MDM IDs. This is how you answer: "What does the broker call MDM-001?"';

-- Populate from existing incoming records
INSERT INTO counterparty_xref (mdm_id, source_system, source_id, source_name, is_primary)
SELECT matched_mdm_id, source_system, source_id, raw_name,
       (match_status = 'AUTO_MERGED' AND match_score >= 95)
FROM incoming_record
WHERE matched_mdm_id IS NOT NULL;

-- Verify: how is MDM-001 known across systems?
SELECT source_system, source_id, source_name, is_primary
FROM counterparty_xref
WHERE mdm_id = 'MDM-001'
ORDER BY source_system;
```

**Expected:** MDM-001 appears as "TEC" in BROKER_FEED and "Tokyo Energy Corporation Ltd." in INVOICE_SYSTEM. This cross-reference is what lets you translate between systems without losing the golden record link.

**Why this matters:** When someone asks "show me all records for Tokyo Energy across all systems," you don't search by name — you search by `mdm_id` and then fan out through `counterparty_xref` to find every system's identifier.

---

## Part I — Bulk Import Simulation: M&A Scenario (15 min)

The hardest test of any MDM system is bulk import — hundreds of records arriving at once from an acquired company. This exercise simulates what happens during a merger and teaches you to predict stewardship workload.

### Task I1: Generate a bulk import batch

Imagine your firm acquires "Pacific Trading Co" with 8 counterparties. Some overlap with your existing golden records, some are new:

```sql
-- Simulate a bulk import from an acquired company's system
INSERT INTO incoming_record (source_system, source_id, raw_name, credit_limit, match_status, matched_mdm_id, match_score) VALUES
-- High-confidence matches (should auto-merge)
('ACQUISITION_IMPORT', 'PAC-001', 'Tokyo Energy Corporation', 5200000, 'PENDING', NULL, NULL),
('ACQUISITION_IMPORT', 'PAC-002', 'Australian Grid Partners Pty Ltd', 3100000, 'PENDING', NULL, NULL),
('ACQUISITION_IMPORT', 'PAC-003', 'NZ Renewable Energy Trust', 2000000, 'PENDING', NULL, NULL),

-- Ambiguous matches (should queue)
('ACQUISITION_IMPORT', 'PAC-004', 'Tokyo Electric Power', 8000000, 'PENDING', NULL, NULL),
('ACQUISITION_IMPORT', 'PAC-005', 'AusGrid Power', 1500000, 'PENDING', NULL, NULL),

-- Clearly new entities
('ACQUISITION_IMPORT', 'PAC-006', 'Singapore LNG Trading Pte Ltd', 4000000, 'PENDING', NULL, NULL),
('ACQUISITION_IMPORT', 'PAC-007', 'Korean Power Exchange', 6000000, 'PENDING', NULL, NULL),
('ACQUISITION_IMPORT', 'PAC-008', 'Philippine Energy Corp', 1000000, 'PENDING', NULL, NULL);
```

### Task I2: Manually score each record

Before the match engine runs, manually predict each record's score against existing golden records. Fill in this table:

| source_id | raw_name | Best Golden Match | Your Score Prediction | Expected Routing |
|-----------|----------|-------------------|-----------------------|------------------|
| PAC-001 | Tokyo Energy Corporation | MDM-001 (Tokyo Energy Corp) | ~85 (fuzzy name match + similar credit) | QUEUE |
| PAC-002 | Australian Grid Partners Pty Ltd | MDM-002 (AUS Grid Partners) | ~70 (partial fuzzy match) | QUEUE |
| PAC-003 | NZ Renewable Energy Trust | MDM-003 (NZ Renewable Trust) | ~88 (very close fuzzy match) | QUEUE |
| PAC-004 | Tokyo Electric Power | MDM-001? | ~35 (different company! "Electric" ≠ "Energy") | NEW |
| PAC-005 | AusGrid Power | MDM-002? | ~40 ("AusGrid" ≠ "AUS Grid Partners") | NEW |
| PAC-006 | Singapore LNG Trading | None | ~0 | NEW |
| PAC-007 | Korean Power Exchange | None | ~0 | NEW |
| PAC-008 | Philippine Energy Corp | None | ~0 | NEW |

### Task I3: Simulate the match engine

Now update the records as if the match engine processed them:

```sql
-- Simulate match engine results
UPDATE incoming_record SET match_status = 'QUEUED', matched_mdm_id = 'MDM-001', match_score = 82.0
WHERE source_id = 'PAC-001';

UPDATE incoming_record SET match_status = 'QUEUED', matched_mdm_id = 'MDM-002', match_score = 71.5
WHERE source_id = 'PAC-002';

UPDATE incoming_record SET match_status = 'QUEUED', matched_mdm_id = 'MDM-003', match_score = 87.0
WHERE source_id = 'PAC-003';

-- PAC-004: This is a TRAP. "Tokyo Electric Power" is NOT "Tokyo Energy Corp"
-- A naive fuzzy matcher might link them. A good one catches the distinction.
UPDATE incoming_record SET match_status = 'QUEUED', matched_mdm_id = 'MDM-001', match_score = 62.0
WHERE source_id = 'PAC-004';

UPDATE incoming_record SET match_status = 'NEW', match_score = 38.0
WHERE source_id = 'PAC-005';

UPDATE incoming_record SET match_status = 'NEW', match_score = 0.0
WHERE source_id IN ('PAC-006', 'PAC-007', 'PAC-008');
```

### Task I4: Work the stewardship queue

Create stewardship entries for the queued records:

```sql
-- Queue the ambiguous matches for steward review
INSERT INTO stewardship_queue (record_a_id, record_b_id, status, conflict_fields) VALUES
(
    (SELECT record_id FROM incoming_record WHERE source_id = 'PAC-001'),
    NULL,
    'OPEN',
    '{"name": "Tokyo Energy Corporation vs Tokyo Energy Corp", "credit_limit": "5200000 vs 5000000"}'
),
(
    (SELECT record_id FROM incoming_record WHERE source_id = 'PAC-002'),
    NULL,
    'OPEN',
    '{"name": "Australian Grid Partners Pty Ltd vs AUS Grid Partners", "credit_limit": "3100000 vs 3000000"}'
),
(
    (SELECT record_id FROM incoming_record WHERE source_id = 'PAC-003'),
    NULL,
    'OPEN',
    '{"name": "NZ Renewable Energy Trust vs NZ Renewable Trust", "credit_limit": "matches"}'
),
(
    (SELECT record_id FROM incoming_record WHERE source_id = 'PAC-004'),
    NULL,
    'OPEN',
    '{"name": "Tokyo Electric Power vs Tokyo Energy Corp — DIFFERENT COMPANY?", "credit_limit": "8000000 vs 5000000"}'
);
```

**Now resolve PAC-004 — this is the critical decision:**

```sql
-- PAC-004: "Tokyo Electric Power" is NOT "Tokyo Energy Corp"
-- This is a false match. Reject the link and create a new golden record.
UPDATE stewardship_queue
SET status = 'RESOLVED',
    resolved_by = 'kenji.tanaka',
    resolution = '{"decision": "reject_match", "rationale": "Tokyo Electric Power (TEPCO) is a separate legal entity from Tokyo Energy Corp. Different company, different credit profile. Create new golden record."}',
    resolved_at = NOW()
WHERE queue_id = (SELECT sq.queue_id FROM stewardship_queue sq
                  JOIN incoming_record ir ON ir.record_id = sq.record_a_id
                  WHERE ir.source_id = 'PAC-004' LIMIT 1);

INSERT INTO golden_record (mdm_id, canonical_name, short_code, credit_limit, currency, data_steward)
VALUES ('MDM-005', 'Tokyo Electric Power Co', 'TEPCO', 8000000, 'JPY', 'kenji.tanaka');

UPDATE incoming_record SET match_status = 'MERGED_NEW', matched_mdm_id = 'MDM-005', match_score = 100.0
WHERE source_id = 'PAC-004';
```

**This is the most important exercise in the entire lab.** You just prevented a false merge that would have combined two different companies' credit limits and trade exposure. In production, this mistake could mean booking a trade against the wrong entity and violating credit limits — a regulatory breach.

### Task I5: Analyze the bulk import results

```sql
-- What was the auto-merge rate for this batch?
SELECT
    match_status,
    COUNT(*) AS count,
    ROUND(COUNT(*) * 100.0 / 8, 1) AS pct_of_batch
FROM incoming_record
WHERE source_system = 'ACQUISITION_IMPORT'
GROUP BY match_status
ORDER BY count DESC;
```

**Expected distribution:** 0% auto-merge (all were ambiguous or new), ~50% queued, ~50% new. This is normal for M&A imports — the acquired company's naming conventions don't match yours, so the match engine can't auto-resolve anything with high confidence.

**Industry benchmark:** M&A bulk imports typically have 10-25% auto-merge rate. If yours is higher, your thresholds might be too aggressive. If it's 0%, that's actually correct for a first-time import from an unknown system.

---

## Part J — Match Engine Tuning: The Science of Thresholds (15 min)

Tuning match thresholds is the most impactful thing an MDM engineer can do. Get it wrong and you either drown stewards in work (thresholds too high) or merge the wrong entities (thresholds too low). This section teaches you to think about this quantitatively.

### The Precision-Recall Trade-off

MDM matching is a classification problem. The match engine classifies each incoming record as:
- **True match** (correctly linked to existing golden record)
- **True non-match** (correctly identified as new entity)
- **False match** (wrongly linked — the dangerous one)
- **False non-match** (wrongly treated as new — annoying but fixable)

```
                    Actual Match    Actual Non-Match
Predicted Match     TRUE POSITIVE   FALSE POSITIVE (false merge)
Predicted Non-Match FALSE NEGATIVE  TRUE NEGATIVE
                    (false sep)
```

### Task J1: Analyze your current threshold performance

```sql
-- Look at the score distribution across all incoming records
SELECT
    CASE
        WHEN match_score >= 90 THEN '90-100 (auto-merge zone)'
        WHEN match_score >= 60 THEN '60-89 (stewardship zone)'
        WHEN match_score >= 30 THEN '30-59 (low confidence)'
        ELSE '0-29 (no match)'
    END AS score_band,
    COUNT(*) AS records,
    STRING_AGG(source_id || ': ' || COALESCE(raw_name, '?'), ', ') AS examples
FROM incoming_record
GROUP BY
    CASE
        WHEN match_score >= 90 THEN '90-100 (auto-merge zone)'
        WHEN match_score >= 60 THEN '60-89 (stewardship zone)'
        WHEN match_score >= 30 THEN '30-59 (low confidence)'
        ELSE '0-29 (no match)'
    END
ORDER BY score_band DESC;
```

### Task J2: What-if analysis — lower the auto-merge threshold

What happens if you lower AUTO_MERGE from 90 to 80?

```sql
-- Which records would have auto-merged at threshold 80 instead of 90?
SELECT source_id, raw_name, match_score, matched_mdm_id, match_status,
    CASE
        WHEN match_score >= 90 THEN 'auto-merge (current)'
        WHEN match_score >= 80 THEN 'WOULD auto-merge at 80'
        WHEN match_score >= 60 THEN 'stewardship'
        ELSE 'new'
    END AS routing_at_80
FROM incoming_record
WHERE match_score BETWEEN 80 AND 89
ORDER BY match_score DESC;
```

**Question:** Look at the records that would auto-merge at threshold 80. Would any of them be false merges? If PAC-001 ("Tokyo Energy Corporation", score 82) had auto-merged to MDM-001, would that be correct? (Answer: yes, in this case. But PAC-004 at score 62 would NOT auto-merge even at 80 — that's where the threshold saves you.)

### Task J3: Build a threshold tuning report

This is the report an MDM engineer presents to management when proposing threshold changes:

```sql
-- Threshold tuning analysis
WITH thresholds AS (
    SELECT unnest(ARRAY[70, 75, 80, 85, 90, 95]) AS threshold
),
analysis AS (
    SELECT
        t.threshold,
        COUNT(*) FILTER (WHERE ir.match_score >= t.threshold AND ir.matched_mdm_id IS NOT NULL) AS would_auto_merge,
        COUNT(*) FILTER (WHERE ir.match_score BETWEEN (t.threshold - 30) AND (t.threshold - 1) AND ir.matched_mdm_id IS NOT NULL) AS would_queue,
        COUNT(*) FILTER (WHERE ir.match_score < (t.threshold - 30) OR ir.matched_mdm_id IS NULL) AS would_be_new,
        COUNT(*) AS total
    FROM incoming_record ir
    CROSS JOIN thresholds t
    GROUP BY t.threshold
)
SELECT
    threshold,
    would_auto_merge,
    would_queue,
    would_be_new,
    ROUND(would_auto_merge * 100.0 / total, 1) AS auto_merge_pct,
    ROUND(would_queue * 100.0 / total, 1) AS queue_pct
FROM analysis
ORDER BY threshold;
```

**How to read this:** Each row shows what happens at a different threshold. As threshold drops, auto-merge rate rises but so does false merge risk. The sweet spot is where auto-merge rate is 70-85% AND you've manually verified that no false merges exist in the auto-merge band.

### Task J4: Weighted scoring sensitivity

Different scoring weights produce different match outcomes. Understand which weights matter most:

```sql
-- Simulate: what if we weighted name matching more heavily?
-- Current: short_code=60, exact_name=50, fuzzy_high=30, fuzzy_low=15
-- Proposed: short_code=40, exact_name=70, fuzzy_high=40, fuzzy_low=20
-- (Rationale: name matching should matter more than short codes,
--  which are abbreviations and prone to collisions)

-- Exercise: For each incoming record, recalculate the score with new weights.
-- Do this mentally or on paper:
--   BRK-8821 ("TEC"):
--     Current: short_code(60) + credit_10%(10) + currency(5) = 75 base + bonus = 92.5
--     Proposed: short_code(40) + credit_10%(10) + currency(5) = 55 base + bonus
--     Result: score DROPS. Short_code-only matches become less confident.
--     Is that good? Maybe — "TEC" could be an abbreviation for many companies.
--
--   INV-2025-441 ("Tokyo Energy Corporation Ltd."):
--     Current: fuzzy_high(30) + credit_diff(-5) = 25 base → 75 with bonuses
--     Proposed: fuzzy_high(40) + credit_diff(-5) = 35 base → 85 with bonuses
--     Result: score RISES. Good names get more credit. This record might auto-merge.
--     Is that good? Yes — the name is clearly the same entity, just with "Ltd." suffix.
```

**Key takeaway:** Weight tuning is how you shift the precision-recall trade-off. Heavier name weights favor records with good names but different short codes. Heavier short_code weights favor records with matching codes but different names. There is no universally correct answer — it depends on your source systems' data quality.

---

## Part K — MDM Audit Trail & Compliance (10 min)

In regulated industries (energy trading, finance), every change to a golden record must be auditable. You need to answer: "Who changed MDM-001's credit limit on January 28th, and why?"

### Task K1: Create an audit log table

```sql
CREATE TABLE IF NOT EXISTS mdm_audit_log (
    audit_id        SERIAL PRIMARY KEY,
    mdm_id          VARCHAR(20) NOT NULL,
    action          VARCHAR(20) NOT NULL,  -- CREATE, UPDATE, MERGE, SPLIT, DEACTIVATE
    field_changed   VARCHAR(50),
    old_value       TEXT,
    new_value       TEXT,
    changed_by      VARCHAR(100) NOT NULL,
    change_reason   TEXT,
    source_ticket   VARCHAR(50),           -- e.g., JIRA ticket, ServiceNow incident
    changed_at      TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE mdm_audit_log IS
  'Every change to golden_record is logged here. Required for SOX compliance and regulatory audits.';

CREATE INDEX idx_audit_mdm_id ON mdm_audit_log(mdm_id);
CREATE INDEX idx_audit_changed_at ON mdm_audit_log(changed_at);
```

### Task K2: Backfill audit entries for changes you already made

```sql
-- Log the credit limit change from Part D
INSERT INTO mdm_audit_log (mdm_id, action, field_changed, old_value, new_value, changed_by, change_reason, source_ticket) VALUES
('MDM-002', 'UPDATE', 'credit_limit', '3000000', '3200000', 'sarah.chen',
 'Risk system confirmed credit increase approved by credit committee', 'CREDIT-2025-0128');

-- Log the new golden record from Part D
INSERT INTO mdm_audit_log (mdm_id, action, field_changed, old_value, new_value, changed_by, change_reason) VALUES
('MDM-004', 'CREATE', NULL, NULL, 'Kansai Power Trading GK', 'kenji.tanaka',
 'New counterparty verified from broker feed BRK-9102');

-- Log the false merge rejection from Part I (if you did it)
INSERT INTO mdm_audit_log (mdm_id, action, field_changed, old_value, new_value, changed_by, change_reason) VALUES
('MDM-005', 'CREATE', NULL, NULL, 'Tokyo Electric Power Co', 'kenji.tanaka',
 'Rejected false match to MDM-001. TEPCO is a separate legal entity from Tokyo Energy Corp. Source: PAC-004');
```

### Task K3: Answer an auditor's question

An auditor asks: "Show me all changes to MDM-001 in the last 90 days."

```sql
SELECT
    action,
    field_changed,
    old_value,
    new_value,
    changed_by,
    change_reason,
    source_ticket,
    changed_at
FROM mdm_audit_log
WHERE mdm_id = 'MDM-001'
  AND changed_at >= NOW() - INTERVAL '90 days'
ORDER BY changed_at DESC;
```

### Task K4: Build a compliance dashboard query

```sql
-- Changes per steward per month (for workload analysis)
SELECT
    changed_by,
    DATE_TRUNC('month', changed_at) AS month,
    COUNT(*) AS total_changes,
    COUNT(*) FILTER (WHERE action = 'CREATE') AS creates,
    COUNT(*) FILTER (WHERE action = 'UPDATE') AS updates,
    COUNT(*) FILTER (WHERE action = 'MERGE') AS merges
FROM mdm_audit_log
GROUP BY changed_by, DATE_TRUNC('month', changed_at)
ORDER BY month DESC, total_changes DESC;
```

**Why this matters:** SOX compliance requires that every data change in a financial system is traceable to a person and a reason. Without this audit log, your MDM system is a liability in any regulated environment.

---

## Part L — MDM System Design Exercise (15 min)

This is the capstone exercise. You're designing an MDM system from scratch for a new energy trading firm. Answer these questions on paper, then check your answers.

### Scenario

A new energy trading firm is going live in 6 months. They will trade electricity in JEPX (Japan), NEM (Australia), and NZEM (New Zealand). They expect:
- ~200 counterparties at launch
- ~50 new counterparties per year
- 4 source systems: trading desk, broker feed, invoice system, risk system
- SOX compliance required
- 3 data stewards (2 in Sydney, 1 in Tokyo)

### Design Questions

**Q1: Schema design.** What tables do you need? (Answer: golden_record, incoming_record, stewardship_queue, counterparty_xref, mdm_audit_log, plus hierarchy columns on golden_record. You just built all of these in this lab.)

**Q2: Match engine thresholds.** What do you set AUTO_MERGE, QUEUE, and NEW thresholds to? (Answer: start at 90/60/60 — conservative. With only 200 counterparties, the stewardship queue won't overflow. After 3 months, analyze the false merge rate and adjust.)

**Q3: Survivorship rules.** For each field, which strategy?

| Field | Strategy | Rationale |
|-------|----------|-----------|
| canonical_name | Longest + manual override | Legal names should be complete, but steward can correct |
| short_code | Source priority (trading desk) | Trading desk assigns official short codes |
| credit_limit | Source priority (risk system) | Only the credit team sets limits |
| currency | Most frequent | Should be consistent across sources |
| is_active | Source priority (risk system) | Risk team controls counterparty status |

**Q4: Kafka event design.** What does a `counterparty.updated` event look like?

```json
{
  "event_type": "counterparty.updated",
  "event_id": "evt-2025-00482",
  "timestamp": "2025-01-28T14:30:00Z",
  "mdm_id": "MDM-002",
  "changed_fields": ["credit_limit"],
  "previous": { "credit_limit": 3000000 },
  "current": {
    "canonical_name": "AUS Grid Partners",
    "short_code": "AGP",
    "credit_limit": 3200000,
    "currency": "AUD",
    "is_active": true
  },
  "changed_by": "sarah.chen",
  "change_reason": "credit_increase_approved",
  "source_ticket": "CREDIT-2025-0128"
}
```

**Why include `changed_fields` and `previous`?** So consumers can decide whether to react. If only the credit limit changed, the trade service updates its Redis cache. If `is_active` changed to false, the trade service blocks all new trades with that counterparty. The consumer shouldn't need to compare the full record — the event tells it exactly what changed.

**Q5: Failure handling.** What happens when:

| Failure | Impact | Mitigation |
|---------|--------|------------|
| MDM Postgres goes down | No new golden record updates. Stewardship queue stuck. | Trade service uses Redis cache with TTL. Trades can still book against cached data. Alert ops team. |
| Kafka goes down | No counterparty.updated events published | MDM queues events internally. On Kafka recovery, replay. Trade service uses stale Redis cache (which is better than no data). |
| A steward bulk-approves without reviewing | False merges get committed | Audit log catches it. Require peer review for bulk operations (>5 records). |
| Redis cache expires | Trade service has no counterparty data | Fall back to direct MDM API call. Slower but correct. Set Redis TTL to 24 hours minimum. |

**Q6: Monitoring.** What metrics would you put on a Grafana dashboard?

Check the pre-built dashboard at `http://localhost:3000` — it already has:
- Golden record count
- Open stewardship items
- Match status distribution (donut chart)
- Auto-merge rate gauge (target: 70-85%)
- Credit utilisation table

What's missing from the dashboard that you'd add in production?
- **Stewardship queue age** — how long has the oldest unresolved conflict been waiting?
- **Match score histogram** — are scores clustering near thresholds (risky)?
- **Event lag** — time between golden record update and Redis cache refresh
- **False merge rate** — monthly count of steward reversals (merges that were undone)

---

## Part M — Clean Up or Keep (2 min)

If you want to reset the MDM database to its original state:

```sql
-- MDM Postgres: remove everything added during the lab
DROP TABLE IF EXISTS mdm_audit_log;
DROP TABLE IF EXISTS counterparty_xref;
DELETE FROM stewardship_queue;
DELETE FROM incoming_record WHERE source_system = 'ACQUISITION_IMPORT';
DELETE FROM incoming_record;
DELETE FROM golden_record WHERE mdm_id IN ('MDM-004', 'MDM-005', 'MDM-GRP-001');

-- Remove hierarchy columns
ALTER TABLE golden_record DROP COLUMN IF EXISTS parent_mdm_id;
ALTER TABLE golden_record DROP COLUMN IF EXISTS hierarchy_level;

-- Reset MDM-002 credit limit to original
UPDATE golden_record SET credit_limit = 3000000, updated_at = NOW() WHERE mdm_id = 'MDM-002';

-- Verify
SELECT mdm_id, canonical_name, credit_limit FROM golden_record ORDER BY mdm_id;
```

**Or keep your changes** — the seed data will re-insert on next container rebuild (`make wipe && make up`).

---

## Checkpoint: What You Should Be Able to Do

### Core MDM (Parts A-G)
- [ ] Connect to MDM Postgres and query all 3 tables (golden_record, incoming_record, stewardship_queue)
- [ ] Explain why counterparty data lives in MDM Postgres instead of MSSQL
- [ ] Explain what a golden record is and why it matters for regulatory and credit risk
- [ ] Trace how a trade in MSSQL references a counterparty in MDM via `counterparty_mdm_id`
- [ ] Explain the match/merge scoring: AUTO_MERGE (>=90), QUEUE (60-89), NEW (<60)
- [ ] Manually calculate a match score given incoming data vs golden data
- [ ] Explain false merges vs false separations and why false merges are worse
- [ ] Apply survivorship rules (source priority, most recent, longest, most frequent, manual)
- [ ] Resolve a stewardship conflict with documented rationale
- [ ] Create a new golden record from an unmatched incoming entity
- [ ] Measure data quality across the 6 dimensions (completeness, accuracy, consistency, timeliness, uniqueness, validity)
- [ ] Publish and consume a `counterparty.updated` Kafka event
- [ ] Explain the three MDM styles (registry, consolidation, coexistence) and identify which one we use
- [ ] Describe what happens when the MDM service goes down

### Advanced MDM (Parts H-L) — the "genius" level
- [ ] Design and query counterparty hierarchies (parent/subsidiary) for group credit exposure
- [ ] Build and query a cross-reference table (counterparty_xref) to translate between system IDs
- [ ] Simulate a bulk M&A import and predict match outcomes before the engine runs
- [ ] Identify and reject a false merge (the PAC-004 TEPCO exercise)
- [ ] Analyze match score distribution across threshold bands
- [ ] Run what-if threshold analysis and explain the precision-recall trade-off
- [ ] Explain how scoring weight changes affect different types of incoming records
- [ ] Design and populate an audit log that satisfies SOX compliance
- [ ] Answer auditor questions using the audit trail
- [ ] Design an MDM system from scratch: schema, thresholds, survivorship rules, Kafka events, failure handling, monitoring
- [ ] Explain what belongs on an MDM monitoring dashboard and what's missing from a basic one

---

## Reflection Questions

1. **Your firm acquires another trading company** with 300 counterparties. 40% overlap with your existing golden records. Walk through how MDM handles this migration. What's the stewardship workload? How long does it take? (You practiced this at small scale in Part I — now think about what happens at 300 records.)

2. **A regulator asks:** "Show me all trades with Tokyo Energy Corp across all systems." Without MDM, you'd search MSSQL for "Tokyo Energy Corp", "TEC", "Tokyo Energy Corporation Ltd." and probably miss some. With MDM, you search for MDM-001 and get everything. **This is the business case for MDM in one sentence.**

3. **You're designing MDM from scratch for a new firm.** What threshold would you set for AUTO_MERGE? Too high (95) = too much steward work. Too low (70) = risk of false merges. How would you tune it over time? (Answer: start conservative at 90, measure false merge rate for 3 months, lower gradually if false merge rate is < 0.1%)

4. **A data steward leaves the company.** Who now owns the golden records where `data_steward = 'kenji.tanaka'`? (Answer: this is an operational risk. MDM systems should have backup stewards and escalation paths. The new hire inherits the records.)

5. **The credit team says:** "We updated Tokyo Energy Corp's credit limit to ¥8M in our system 2 weeks ago, but the trade service is still using ¥5M." Trace the failure. Where did the pipeline break? (Answer: either the credit system didn't send the update to MDM, the MDM match engine didn't process it, or the Kafka event wasn't consumed by the trade service. Check `incoming_record` for the credit system's record, check `counterparty.updated` topic for the event, check `mdm_audit_log` for the change.)

### Advanced (if you completed Parts H-L)

6. **Your firm trades with 3 subsidiaries of the same holding company.** Each has a ¥5M credit limit. The holding company has a group limit of ¥12M. You've already used ¥4M with subsidiary A, ¥4M with B, and ¥3M with C. Can you book a ¥2M trade with subsidiary A? (Answer: subsidiary A still has ¥1M headroom. But group aggregate is ¥11M + ¥2M = ¥13M > ¥12M group limit. The trade must be rejected. Without hierarchy modeling, you'd never catch this.)

7. **Two stewards disagree on how to resolve a conflict.** Steward A says merge, Steward B says reject. Your audit log will show both actions. How do you design the stewardship process to prevent this? (Answer: assign one primary steward per entity domain. Require peer review for high-impact changes like credit limit changes > 20%. Build escalation paths in the stewardship queue.)

8. **Your match engine is auto-merging at 92% rate.** Is that good or bad? (Answer: suspicious. Check your audit log for false merges that were later reversed. If reversal rate is < 0.1%, you're fine. If it's > 1%, your thresholds are too aggressive. Also check: are you mostly processing records from one well-structured source system? That inflates auto-merge rate.)

9. **You need to split a golden record.** MDM-001 was used for two different legal entities that were incorrectly merged a year ago. 47 trades reference MDM-001. Walk through the split process. (Answer: create MDM-001a and MDM-001b. Reassign trades based on the original `counterparty_xref` source IDs. Publish two `counterparty.updated` events. Update Redis cache. Log everything in audit trail with the JIRA ticket number. This is the most painful MDM operation and is why false merges are worse than false separations.)

10. **You're presenting your MDM system to the board.** They ask: "How do we know this system is working?" What 3 metrics would you show them? (Answer: (1) Auto-merge rate trend over time — should stabilize at 70-85%. (2) Stewardship queue age — average time to resolution should be < 48 hours. (3) False merge rate — should be < 0.1% per quarter. These prove the system is accurate, responsive, and trustworthy.)

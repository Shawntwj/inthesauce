# Lab 2 — Kafka: Topics, Messages, Consumer Lag

**Prereqs:** Lab 1 complete. Docker stack running.
**Time:** 30 minutes
**Goal:** Understand how messages flow through Kafka and how to debug it.

---

## Part A — Inspect What's Running (10 min)

### Task A1: List all topics
```bash
docker exec etrm-kafka kafka-topics \
  --list --bootstrap-server localhost:9092
```

**Expected output:**
```
counterparty.updated
market.prices
pnl.calc
settlement.run
trade.events
```

Write down: what does each topic carry? (See `docs/kafka_guide.md` if unsure)

### Task A2: Describe a topic
```bash
docker exec etrm-kafka kafka-topics \
  --describe --topic trade.events \
  --bootstrap-server localhost:9092
```

Read the output. Note:
- How many **partitions** does it have?
- What is the **replication factor**?
- What does `retention.ms` tell you?

### Task A3: Check consumer groups and lag

First, list all consumer groups:
```bash
docker exec etrm-kafka kafka-consumer-groups \
  --bootstrap-server localhost:9092 \
  --list
```

> **Note:** If no consumer groups appear, that's expected — the Go service isn't built yet. Consumer groups are created when a service (or console consumer with `--group`) starts consuming. You'll create one in Part C.

If any groups exist, inspect one:
```bash
docker exec etrm-kafka kafka-consumer-groups \
  --bootstrap-server localhost:9092 \
  --describe --group <group-name>
```

**Read the output:**
- `CURRENT-OFFSET` — last message the consumer processed
- `LOG-END-OFFSET` — last message in the topic
- `LAG` — how many messages behind the consumer is

**Question:** What does LAG = 0 mean vs LAG = 50? (Answer: LAG = 0 means the consumer is caught up. LAG = 50 means 50 messages arrived that haven't been processed yet — the consumer is behind.)

---

## Part B — Watch Messages Flow (10 min)

### Task B1: Watch trade.events in real time
Open a terminal and run:
```bash
docker exec etrm-kafka kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic trade.events \
  --from-beginning
```

Leave this running. You should see any existing messages replay from the beginning.

Press `Ctrl+C` when done.

### Task B2: Watch market prices
```bash
docker exec etrm-kafka kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic market.prices \
  --from-beginning \
  --max-messages 5
```

**Expected:** 5 JSON messages with price data. Note the structure — what fields does each message have?

### Task B3: Publish a test message manually
Open a producer:
```bash
docker exec -it etrm-kafka kafka-console-producer \
  --bootstrap-server localhost:9092 \
  --topic trade.events
```

Now type this JSON and press Enter:
```json
{"event_type":"trade.created","trade_id":99,"unique_id":"TEST-LAB2","counterparty_mdm_id":"MDM-001","area_id":1}
```

Press `Ctrl+C` to exit the producer.

**Verify it arrived** — run the consumer again:
```bash
docker exec etrm-kafka kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic trade.events \
  --from-beginning \
  --max-messages 100 | grep TEST-LAB2
```

**Expected:** Your message appears in the output.

**Question:** If the Go service was running and consumed this message, what would it try to do with a trade_id of 99? (It would try to find trade_id=99 in MSSQL, fail, and log an error — that's fine, it's a test message.)

---

## Part C — Simulate Consumer Lag (10 min)

### Task C1: Count messages in a topic
```bash
docker exec etrm-kafka kafka-run-class kafka.tools.GetOffsetShell \
  --broker-list localhost:9092 \
  --topic market.prices \
  --time -1
```

This shows the latest offset (= total messages) per partition.

### Task C2: Check Grafana for Kafka metrics
Open `http://localhost:3000` → Dashboards → find the system health or Kafka dashboard.

Look for:
- Consumer lag panels
- Messages in/out per second
- Topic partition counts

**If no Kafka dashboard exists yet:** that's a good exercise — go to Dashboards → New → add a panel with Prometheus datasource and query `kafka_consumer_lag_sum`.

### Task C3: Understand what happens when a consumer goes down
Think through this scenario:
1. Market prices are publishing to `market.prices` every 30 seconds
2. The Go service (consumer) crashes
3. Prices keep publishing — messages queue up in Kafka
4. Go service comes back up 5 minutes later
5. It reads from its last committed offset — processes all 10 missed messages in order

**Question:** After the Go service recovers, what happens to the `mtm_price` values in ClickHouse? Are they updated correctly?

(Answer: Yes — each message inserts a new row with the updated `mtm_price` and new `issue_datetime`. ClickHouse's `argMax` returns the latest one. No data is lost.)

---

## Part D — Trace a Record End-to-End (10 min)

This is the most important technique in distributed systems: **trace a single record from source to sink.**

### Task D1: Publish a counterparty update and trace it

1. **Publish to Kafka** (simulating the MDM service):
```bash
echo '{"event_type":"counterparty.updated","mdm_id":"MDM-001","canonical_name":"Tokyo Energy Corp","credit_limit":5500000,"currency":"JPY","updated_by":"kenji.tanaka"}' | \
docker exec -i etrm-kafka kafka-console-producer \
  --bootstrap-server localhost:9092 \
  --topic counterparty.updated
```

2. **Verify it arrived in Kafka:**
```bash
docker exec etrm-kafka kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic counterparty.updated \
  --from-beginning --max-messages 5
```

3. **Check the golden record in MDM Postgres** (open DBeaver → `localhost:5432`):
```sql
SELECT mdm_id, canonical_name, credit_limit, updated_at
FROM golden_record WHERE mdm_id = 'MDM-001';
```

The credit limit is still ¥5M — because we only published a *Kafka event*, we didn't update the database. In production, the MDM service updates the DB *first*, then publishes the event. The event is a *notification*, not the source of truth.

**Key insight:** This is why the pattern is "write to DB → publish event", not "publish event → hope someone writes to DB." The database is the source of truth. Kafka is the notification bus.

### Task D2: Understand the full data flow on paper

Trace what happens when the credit team updates a counterparty's credit limit:

```
Credit Team System → POST /counterparties/ingest to MDM Service
  → MDM Service: match engine scores the incoming record
  → If score >= 90: auto-merge → UPDATE golden_record
  → MDM Service: publish to Kafka topic "counterparty.updated"
  → Trade Service: Kafka consumer receives the event
  → Trade Service: updates Redis cache with new credit limit
  → Next trade booking: credit check uses Redis → sees new limit
```

**Exercise:** What if step 4 (Kafka publish) fails after step 3 (DB update)? The golden record has the new limit but downstream services don't know. This is called a **dual-write problem**. Solutions: transactional outbox pattern, or retry the publish.

---

## Checkpoint: What You Should Be Able to Do

- [ ] List all Kafka topics and describe what each carries
- [ ] Check consumer lag and explain what it means
- [ ] Consume messages from a topic and read the output
- [ ] Publish a message manually and verify it arrived
- [ ] Explain what happens to queued messages when a consumer recovers
- [ ] Trace a record end-to-end: Kafka event → database → downstream system
- [ ] Explain why the pattern is "write to DB first, then publish event"

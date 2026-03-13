# Kafka Guide — Messaging in This Stack

---

## What Kafka Does Here

When a trade is created, multiple things need to happen independently:
- Save to MSSQL
- Explode to ClickHouse
- Run credit check
- Archive payload to S3
- Notify risk desk

You don't do all of this in one synchronous REST call. Instead:
1. API receives the trade → validates → saves to MSSQL
2. API publishes a `trade.created` event to Kafka
3. Each downstream service consumes the event and does its own job
4. If one consumer fails → it retries from its last offset, nothing is lost

This is the **event-driven** pattern. Kafka is the message bus.

---

## Topics in This Stack

| Topic | Published By | Consumed By | What It Carries |
|---|---|---|---|
| `trade.events` | Go service (POST /trades) | Go service (exploder, credit check) | Full trade payload — counterparty MDM ID, components, delivery details |
| `market.prices` | Market data scraper (synthetic) | Go service (MTM updater) | Half-hourly prices per area: `{area_id, value_datetime, price, volume}` |
| `settlement.run` | Cron / manual trigger | Go service (settlement engine) | Settlement run command: `{trade_id, period_start, period_end}` |
| `pnl.calc` | Go service (after market price update) | Go service (P&L engine) | P&L recalc request: `{trade_id, as_of_datetime}` |
| `counterparty.updated` | MDM service (port 8081) | ETRM trade service (Redis cache updater) | Golden record change: `{mdm_id, canonical_name, short_code, credit_limit, currency, is_active}` |

---

## Core Concepts

### Topic
A named channel. Messages go in one end, consumers read from the other.
Topics are split into **partitions** — like parallel lanes. More partitions = more parallelism.

### Offset
Every message in a partition has a sequential number (offset 0, 1, 2, ...).
Consumers track which offset they've read up to. If a consumer crashes, it restarts from its last committed offset — no messages lost.

### Consumer Group
Multiple instances of the same service share a consumer group. Kafka distributes partitions across instances automatically.
- 1 service instance + 4 partitions → instance reads all 4
- 2 service instances + 4 partitions → each instance reads 2

### Retention
Kafka keeps messages for 7 days by default (configurable). Even after a consumer reads a message, it stays on disk. Another consumer group can read from the beginning.

---

## Hands-On: Inspect Topics

```bash
# List all topics
docker exec etrm-kafka kafka-topics \
  --list --bootstrap-server localhost:9092

# Describe a topic (partitions, replication, etc.)
docker exec etrm-kafka kafka-topics \
  --describe --topic trade.events --bootstrap-server localhost:9092

# Check consumer group lag (how far behind is the consumer?)
docker exec etrm-kafka kafka-consumer-groups \
  --bootstrap-server localhost:9092 \
  --describe --group etrm-service
```

**Understanding lag output:**
```
GROUP         TOPIC         PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG
etrm-service  trade.events  0          42              42              0    <- healthy, caught up
etrm-service  market.prices 0          1205            1210            5    <- 5 messages behind
```
Lag > 0 means the consumer is falling behind. High lag = the Go service is overloaded or crashed.

---

## Hands-On: Publish and Consume Messages Manually

### Watch a topic in real time (consumer)
```bash
# Watch trade.events — will print any new messages as they arrive
docker exec etrm-kafka kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic trade.events \
  --from-beginning
```
Press `Ctrl+C` to stop.

### Publish a test message (producer)
```bash
# Open a producer for trade.events
docker exec -it etrm-kafka kafka-console-producer \
  --bootstrap-server localhost:9092 \
  --topic trade.events

# Now type a JSON message and press Enter:
{"trade_id": 99, "unique_id": "TEST-001", "counterparty_mdm_id": "MDM-001", "action": "test"}
```
If the Go service is running, it will try to consume and process this message.

### Read messages from the beginning (audit / debugging)
```bash
# Read all market.prices messages ever published
docker exec etrm-kafka kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic market.prices \
  --from-beginning \
  --max-messages 10
```

---

## How the Go Service Uses Kafka

### Producer (publishing events)
When a trade is created via REST API:
```
POST /trades  →  validate  →  save to MSSQL  →  publish to trade.events  →  return 201
```

### Consumer (processing events)
A goroutine runs in the background listening to each topic:
```
trade.events          →  explode trade to ClickHouse half-hour intervals
market.prices         →  update mtm_price in transaction_exploded
settlement.run        →  generate invoices for completed trades
pnl.calc              →  recalculate P&L and write updated rows to ClickHouse
counterparty.updated  →  update Redis cache with latest golden record from MDM
```

### Why async?
- Trade explosion might create 1,000+ ClickHouse rows — too slow to do synchronously in the API call
- Market price updates come every 30 seconds — processing them one at a time in the API would block everything else
- If ClickHouse is temporarily slow, messages queue in Kafka and catch up later

---

## Deep Dive: counterparty.updated Topic

This topic is the bridge between the MDM service and the ETRM trade service. When a golden record changes (auto-merge, steward resolution, or manual update), the MDM service publishes an event here.

### Message format
```json
{
  "mdm_id": "MDM-001",
  "canonical_name": "Tokyo Energy Corp",
  "short_code": "TEC",
  "credit_limit": 6000000,
  "currency": "JPY",
  "is_active": true
}
```

### Publish a test event
```bash
echo '{"mdm_id":"MDM-001","canonical_name":"Tokyo Energy Corp","short_code":"TEC","credit_limit":6000000,"currency":"JPY","is_active":true}' | \
docker exec -i etrm-kafka kafka-console-producer \
  --bootstrap-server localhost:9092 \
  --topic counterparty.updated
```

### Consume it back
```bash
docker exec etrm-kafka kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic counterparty.updated \
  --from-beginning \
  --max-messages 5
```

### What the ETRM trade service does with this event
1. Receives the message from the `counterparty.updated` topic
2. Parses the JSON into a `GoldenRecord` struct
3. Writes to Redis: `SET counterparty:MDM-001 <json> EX 3600` (1-hour TTL)
4. Next credit check for MDM-001 reads from Redis instead of calling the MDM API

### Why this pattern matters
- **Decoupling:** ETRM doesn't depend on MDM being up for every credit check
- **Speed:** Redis read (~1ms) vs MDM API call (~50ms)
- **Consistency:** Eventual — if MDM updates a credit limit, there's a brief window where ETRM uses the old value (until the Kafka event arrives and Redis updates)

---

## What Goes Wrong and How to Debug

### Consumer lag is growing
```bash
# Check lag
docker exec etrm-kafka kafka-consumer-groups \
  --bootstrap-server localhost:9092 --describe --group etrm-service

# Check Go service logs
docker compose logs trade-service --tail=50
```
Likely cause: Go service is down, or ClickHouse write is slow.

### Message published but nothing happened
```bash
# Confirm the message arrived in the topic
docker exec etrm-kafka kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic trade.events --from-beginning --max-messages 5

# Check if consumer group has committed offsets
docker exec etrm-kafka kafka-consumer-groups \
  --bootstrap-server localhost:9092 \
  --describe --group etrm-service
```

### Kafka won't start
```bash
docker compose logs kafka --tail=30
docker compose logs zookeeper --tail=30
# Usually a Zookeeper connection issue — restart both
docker compose restart zookeeper kafka
```

---

## Key Things to Know on the Job

1. **Kafka is not a database.** Don't treat it as permanent storage. After retention expires, messages are gone. The databases (MSSQL, ClickHouse) are the permanent record.

2. **At-least-once delivery.** A message may be processed more than once (if consumer crashes after processing but before committing offset). Your consumers must be **idempotent** — processing the same trade twice should not create two rows. This is why ClickHouse uses `ReplacingMergeTree` (same key = deduplicated) and MSSQL uses `UNIQUE` constraints.

3. **Consumer groups isolate workloads.** The settlement engine and the P&L engine can both consume from `trade.events` independently using different consumer group IDs. They each maintain their own offset.

4. **Partition count determines parallelism.** If you need to process `market.prices` faster, add partitions and scale the Go service to more instances. Each instance will handle a subset of partitions.

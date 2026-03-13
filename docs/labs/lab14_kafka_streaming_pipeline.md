# Lab 14 — Kafka Streaming Pipeline: Real-Time Market Data

**Prereqs:** Labs 1, 2 complete. All containers running. Python 3.9+ or Go installed.
**Time:** 60-90 minutes
**Goal:** Build a real-time market data pipeline — produce synthetic prices, consume them, insert into ClickHouse, and watch dashboards update live.

---

## Why This Matters

Lab 2 taught you to manually produce/consume Kafka messages. But in production, market data flows continuously — JEPX publishes prices every 30 minutes, NEM every 5 minutes, NZEM every 30 minutes. The pipeline that ingests this data and makes it queryable in under 5 seconds is what makes a trading desk competitive.

This is also the most common system design interview question in energy tech: "design a real-time market data ingestion pipeline."

---

## Part A — Build a Price Producer (20 min)

### Task A1: Write a Python market data simulator

Create `scripts/market_data_producer.py`:

```python
#!/usr/bin/env python3
"""
Simulates real-time market data for JEPX, NEM, and NZEM.
Publishes to Kafka topic 'market.prices' every 5 seconds.
"""

import json
import time
import random
from datetime import datetime, timezone
from kafka import KafkaProducer

MARKETS = {
    1: {"name": "JEPX", "base_price": 11.0, "volatility": 2.0, "currency": "JPY"},
    2: {"name": "NEM",  "base_price": 80.0, "volatility": 15.0, "currency": "AUD"},
    3: {"name": "NZEM", "base_price": 60.0, "volatility": 10.0, "currency": "NZD"},
}

def generate_price(market):
    """Generate a realistic price with random walk."""
    change = random.gauss(0, market["volatility"] * 0.1)
    market["base_price"] = max(0.01, market["base_price"] + change)
    return round(market["base_price"], 4)

def main():
    producer = KafkaProducer(
        bootstrap_servers="localhost:9092",
        value_serializer=lambda v: json.dumps(v).encode("utf-8"),
        key_serializer=lambda k: k.encode("utf-8") if k else None,
    )

    print("Market data producer started. Press Ctrl+C to stop.")
    seq = 0

    while True:
        now = datetime.now(timezone.utc)

        for area_id, market in MARKETS.items():
            price = generate_price(market)
            volume = round(random.uniform(100, 500), 1)

            message = {
                "event_type": "market.price_update",
                "area_id": area_id,
                "market_area": market["name"],
                "price": price,
                "volume": volume,
                "currency": market["currency"],
                "value_datetime": now.isoformat(),
                "source": "SIMULATOR",
                "sequence": seq,
            }

            producer.send(
                "market.prices",
                key=str(area_id),
                value=message,
            )
            print(f"  [{market['name']}] {market['currency']} {price:.4f}  vol={volume}")

        producer.flush()
        seq += 1
        print(f"--- Batch {seq} sent at {now.strftime('%H:%M:%S')} ---")
        time.sleep(5)

if __name__ == "__main__":
    main()
```

### Task A2: Install dependencies and run

```bash
pip install kafka-python clickhouse-connect
python scripts/market_data_producer.py
```

> **Tip:** If you want to isolate dependencies, use a virtual environment:
> ```bash
> python -m venv .venv && source .venv/bin/activate
> pip install kafka-python clickhouse-connect
> ```

You should see prices printing every 5 seconds. Leave it running.

### Task A3: Verify messages are arriving

In a new terminal:
```bash
docker exec etrm-kafka kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic market.prices \
  --max-messages 3
```

---

## Part B — Build a Price Consumer (25 min)

### Task B1: Write a consumer that inserts into ClickHouse

Create `scripts/market_data_consumer.py`:

```python
#!/usr/bin/env python3
"""
Consumes market.prices from Kafka and inserts into ClickHouse.
This is the "ingestion" side of the pipeline.
"""

import json
from datetime import datetime, timezone
from kafka import KafkaConsumer
import clickhouse_connect

def main():
    # Connect to ClickHouse
    ch = clickhouse_connect.get_client(
        host="localhost", port=8123,
        database="etrm",
    )

    # Connect to Kafka
    consumer = KafkaConsumer(
        "market.prices",
        bootstrap_servers="localhost:9092",
        group_id="market-data-ingestion",
        auto_offset_reset="latest",
        value_deserializer=lambda m: json.loads(m.decode("utf-8")),
    )

    print("Consumer started. Waiting for messages...")
    batch = []
    batch_size = 10  # Insert every 10 messages for efficiency

    for msg in consumer:
        data = msg.value
        now = datetime.now(timezone.utc)

        batch.append([
            data["value_datetime"][:10],           # value_date
            data["value_datetime"],                 # value_datetime
            now.strftime("%Y-%m-%d %H:%M:%S"),     # issue_datetime
            data["area_id"],                        # area_id
            data["price"],                          # price
            data["volume"],                         # volume
            data["source"],                         # source
            data["currency"],                       # currency
        ])

        if len(batch) >= batch_size:
            ch.insert(
                "market_data",
                batch,
                column_names=[
                    "value_date", "value_datetime", "issue_datetime",
                    "area_id", "price", "volume", "source", "currency",
                ],
            )
            print(f"  Inserted {len(batch)} rows into ClickHouse")
            batch = []

    # Insert remaining
    if batch:
        ch.insert("market_data", batch, column_names=[
            "value_date", "value_datetime", "issue_datetime",
            "area_id", "price", "volume", "source", "currency",
        ])

if __name__ == "__main__":
    main()
```

### Task B2: Run the consumer

```bash
python scripts/market_data_consumer.py
```

> If you installed dependencies in Task A2, `clickhouse-connect` is already available.

### Task B3: Verify data is flowing

With both producer and consumer running, check ClickHouse:

```sql
SELECT
    area_id,
    CASE area_id WHEN 1 THEN 'JEPX' WHEN 2 THEN 'NEM' WHEN 3 THEN 'NZEM' END AS market,
    argMax(price, issue_datetime) AS latest_price,
    argMax(source, issue_datetime) AS source,
    max(issue_datetime) AS last_update
FROM etrm.market_data
GROUP BY area_id
ORDER BY area_id;
```

**Expected:** `source = SIMULATOR` and `last_update` should be within the last few seconds.

---

## Part C — Monitor the Pipeline (15 min)

### Task C1: Check consumer lag

```bash
docker exec etrm-kafka kafka-consumer-groups \
  --bootstrap-server localhost:9092 \
  --describe --group market-data-ingestion
```

**LAG should be 0 or close to 0.** If it's growing, your consumer is slower than your producer.

### Task C2: Watch Superset dashboards update

1. Open `http://localhost:8088/superset/dashboard/1/` (Market Data dashboard)
2. Click the refresh button or set auto-refresh to 30 seconds
3. You should see the latest prices from your simulator appearing in the charts

### Task C3: Simulate a pipeline failure

1. Stop the consumer (`Ctrl+C`)
2. Leave the producer running for 1 minute (messages will queue in Kafka)
3. Check consumer lag: `kafka-consumer-groups --describe --group market-data-ingestion`
   - LAG should be growing
4. Restart the consumer
5. Watch it catch up — LAG should drop back to 0

**This is exactly how Kafka works in production.** Consumers crash, get restarted, and catch up. No data is lost because Kafka retains messages for 7 days.

---

## Part D — Advanced: Windowed Aggregations (20 min)

### Task D1: Calculate VWAP (Volume-Weighted Average Price)

VWAP is the standard metric traders use for "what's the fair price today?"

```sql
-- ClickHouse: VWAP per market area for the last 24 hours
SELECT
    area_id,
    CASE area_id WHEN 1 THEN 'JEPX' WHEN 2 THEN 'NEM' WHEN 3 THEN 'NZEM' END AS market,
    sum(price * volume) / sum(volume) AS vwap,
    sum(volume) AS total_volume,
    count(*) AS price_updates,
    min(price) AS low,
    max(price) AS high,
    argMax(price, issue_datetime) AS last_price
FROM etrm.market_data FINAL
WHERE value_datetime >= now() - INTERVAL 24 HOUR
GROUP BY area_id
ORDER BY area_id;
```

### Task D2: Detect price spikes in real-time

```sql
-- ClickHouse: prices that deviate > 2 standard deviations from rolling mean
SELECT
    value_datetime,
    area_id,
    price,
    avg(price) OVER w AS rolling_avg,
    stddevPop(price) OVER w AS rolling_std,
    abs(price - avg(price) OVER w) / nullIf(stddevPop(price) OVER w, 0) AS z_score
FROM etrm.market_data FINAL
WHERE area_id = 1
  AND value_datetime >= now() - INTERVAL 24 HOUR
WINDOW w AS (
    ORDER BY value_datetime
    ROWS BETWEEN 20 PRECEDING AND 1 PRECEDING
)
ORDER BY value_datetime DESC
LIMIT 20;
```

Rows with `z_score > 2.0` are potential anomalies.

### Task D3: Build a VWAP chart in Superset

1. Open SQL Lab → ETRM ClickHouse
2. Run the VWAP query from Task D1
3. Click **Explore** → select **Big Number with Trendline**
4. Save as "JEPX VWAP" and add to the Market Data dashboard

---

## Part E — Production Considerations (10 min)

Think through these questions — they come up in system design interviews:

1. **Ordering:** Kafka partitions are ordered, but your producer uses `area_id` as the key. What does this guarantee? (All prices for the same area go to the same partition, preserving order within that area.)

2. **Exactly-once:** If the consumer crashes after consuming a message but before inserting to ClickHouse, what happens on restart? (It re-processes the message. ClickHouse handles this via ReplacingMergeTree — duplicate rows are merged by `issue_datetime`.)

3. **Backpressure:** What if ClickHouse is slow and the consumer can't keep up? (Lag grows. Options: increase batch size, add more consumer instances, or add more partitions.)

4. **Schema evolution:** What if the producer starts sending a new field `bid_price`? (Kafka doesn't enforce schemas. The consumer ignores unknown fields. To enforce: use Kafka Schema Registry with Avro or Protobuf.)

5. **Multi-datacenter:** If you have producers in Tokyo and Sydney, how do you ensure consistent ordering? (You don't — each region has its own Kafka cluster. Cross-region replication uses MirrorMaker 2 with eventual consistency.)

---

## Checkpoint: What You Should Be Able to Do

- [ ] Build a Kafka producer that simulates real-time market data
- [ ] Build a Kafka consumer that inserts into ClickHouse in batches
- [ ] Monitor consumer lag and understand what it means
- [ ] Simulate a pipeline failure and verify recovery
- [ ] Calculate VWAP and detect price anomalies
- [ ] Explain at-least-once delivery and how ClickHouse handles duplicates
- [ ] Answer system design questions about real-time data pipelines

---

## What Makes This World-Class

Building a working pipeline is table stakes. What elevates you:

1. **Batch efficiency** — inserting 10 rows at a time vs 1 is 10x faster. Inserting 1000 is 100x faster.
2. **Idempotent consumers** — your pipeline can crash and restart without duplicating data
3. **Monitoring** — you have lag metrics, not just hope
4. **Anomaly detection** — you catch bad data before it hits the dashboard
5. **Back-of-envelope math** — "JEPX publishes 48 prices/day × 3 areas = 144 rows/day. Our pipeline handles 10,000 rows/second. We have 69,000x headroom."

# Lab 10 — Build the Go Trade Service from Scratch

**Prereqs:** Labs 1-4 complete. Go 1.22+ installed (`brew install go`).
**Time:** 2-3 hours
**Goal:** Build a production-quality REST API that ingests trades, explodes them to ClickHouse, and calculates P&L — the core of any ETRM system.

---

## Why This Matters

Labs 1-9 taught you how the data flows and where it lives. But in a real firm, someone has to **write the service** that makes it all work. This is the highest-leverage skill in energy tech — the person who can build the trade service owns the pipeline.

> **Important:** The `services/` directory does not exist yet — that's the point of this lab. You're building it from scratch. This lab provides the structs, algorithms, and architecture. You write the code, wire it together, and make it work. If you're new to Go, install it first (`brew install go`) and spend 30 minutes on the [Go Tour](https://go.dev/tour/) before starting.

---

## Part A — Project Scaffolding (20 min)

### Task A1: Initialise the Go module

```bash
mkdir -p services/trade-service && cd services/trade-service
go mod init github.com/inthesauce/trade-service
```

### Task A2: Create the directory structure

```
services/trade-service/
├── cmd/
│   └── server/
│       └── main.go           # Entry point
├── internal/
│   ├── api/
│   │   ├── router.go         # HTTP routes
│   │   └── handlers.go       # Request handlers
│   ├── domain/
│   │   ├── trade.go           # Trade structs + business rules
│   │   └── explosion.go       # Trade → half-hour intervals
│   ├── store/
│   │   ├── mssql.go           # MSSQL repository
│   │   └── clickhouse.go      # ClickHouse repository
│   └── kafka/
│       ├── producer.go        # Event publisher
│       └── consumer.go        # Event consumer
├── go.mod
└── go.sum
```

### Task A3: Install dependencies

```bash
go get github.com/gin-gonic/gin
go get github.com/denisenkom/go-mssqldb
go get github.com/ClickHouse/clickhouse-go/v2
go get github.com/segmentio/kafka-go
go get github.com/prometheus/client_golang/prometheus
```

---

## Part B — Domain Models (20 min)

### Task B1: Define the trade struct

Create `internal/domain/trade.go`:

```go
package domain

import "time"

type Trade struct {
    TradeID           int       `json:"trade_id"`
    UniqueID          string    `json:"unique_id"`
    TotalQuantity     float64   `json:"total_quantity"`
    TradeAtUTC        time.Time `json:"trade_at_utc"`
    IsActive          bool      `json:"is_active"`
    IsHypothetical    bool      `json:"is_hypothetical"`
    CounterpartyMDMID string    `json:"counterparty_mdm_id"`
    TraderID          int       `json:"trader_id"`
    BookID            int       `json:"book_id"`
    Components        []TradeComponent `json:"components"`
}

type TradeComponent struct {
    ComponentID       int       `json:"component_id"`
    TradeID           int       `json:"trade_id"`
    AreaID            int       `json:"area_id"`       // 1=JEPX, 2=NEM, 3=NZEM
    DeliveryProfileID int       `json:"delivery_profile_id"`
    SettlementMode    string    `json:"settlement_mode"` // PHYSICAL, FINANCIAL
    Currency          string    `json:"currency"`
    ProductType       string    `json:"product_type"`    // STANDARD, CONSTANT, VARIABLE
    Quantity          float64   `json:"quantity"`         // MW
    Price             float64   `json:"price"`
    StartDate         time.Time `json:"start_date"`
    EndDate           time.Time `json:"end_date"`
}

// ExplodedInterval is a single 30-minute delivery slot in ClickHouse.
type ExplodedInterval struct {
    TradeID        int       `json:"trade_id"`
    ComponentID    int       `json:"component_id"`
    UniqueID       string    `json:"unique_id"`
    IntervalStart  time.Time `json:"interval_start"`
    IntervalEnd    time.Time `json:"interval_end"`
    Quantity       float64   `json:"quantity"`
    Price          float64   `json:"price"`
    SettlePrice    *float64  `json:"settle_price"`
    MTMPrice       *float64  `json:"mtm_price"`
    RealizedPnL    *float64  `json:"realized_pnl"`
    UnrealizedPnL  *float64  `json:"unrealized_pnl"`
    AreaID         int       `json:"area_id"`
    Currency       string    `json:"currency"`
    IssueDateTime  time.Time `json:"issue_datetime"`
}
```

**Question to answer before moving on:** Why does `ExplodedInterval` have `IssueDateTime`? What happens if you insert the same trade_id + interval_start twice with different issue_datetimes?

---

## Part C — Trade Explosion Engine (30 min)

This is the core algorithm. A trade with delivery period Feb 1-28, STANDARD product = 28 days × 48 half-hours = 1,344 rows.

### Task C1: Implement the explosion

Create `internal/domain/explosion.go`:

```go
package domain

import "time"

// Explode converts a trade component into half-hour delivery intervals.
// This is the core of any ETRM system — "turning a deal into cashflows."
func Explode(trade Trade, comp TradeComponent) []ExplodedInterval {
    var intervals []ExplodedInterval
    now := time.Now().UTC()

    slot := time.Date(
        comp.StartDate.Year(), comp.StartDate.Month(), comp.StartDate.Day(),
        0, 0, 0, 0, time.UTC,
    )
    end := time.Date(
        comp.EndDate.Year(), comp.EndDate.Month(), comp.EndDate.Day(),
        23, 30, 0, 0, time.UTC,
    )

    for slot.Before(end) || slot.Equal(end) {
        if shouldInclude(slot, comp) {
            intervals = append(intervals, ExplodedInterval{
                TradeID:       trade.TradeID,
                ComponentID:   comp.ComponentID,
                UniqueID:      trade.UniqueID,
                IntervalStart: slot,
                IntervalEnd:   slot.Add(30 * time.Minute),
                Quantity:      comp.Quantity,
                Price:         comp.Price,
                AreaID:        comp.AreaID,
                Currency:      comp.Currency,
                IssueDateTime: now,
            })
        }
        slot = slot.Add(30 * time.Minute)
    }

    return intervals
}

// shouldInclude filters slots based on delivery profile rules.
func shouldInclude(slot time.Time, comp TradeComponent) bool {
    switch comp.ProductType {
    case "STANDARD":
        return true // 24h, 7 days a week
    case "CONSTANT":
        // Business hours only: 07:00-17:00, weekdays
        hour := slot.Hour()
        weekday := slot.Weekday()
        return weekday >= time.Monday && weekday <= time.Friday &&
            hour >= 7 && hour < 17
    case "VARIABLE":
        // Extended hours: 06:00-22:00
        hour := slot.Hour()
        return hour >= 6 && hour < 22
    default:
        return true
    }
}
```

### Task C2: Write a test

Create `internal/domain/explosion_test.go`:

```go
package domain

import (
    "testing"
    "time"
)

func TestExplode_StandardProduct(t *testing.T) {
    trade := Trade{TradeID: 1, UniqueID: "TEST-001"}
    comp := TradeComponent{
        ComponentID: 1,
        ProductType: "STANDARD",
        Quantity:    100.0,
        Price:       11.50,
        StartDate:   time.Date(2025, 2, 1, 0, 0, 0, 0, time.UTC),
        EndDate:     time.Date(2025, 2, 28, 0, 0, 0, 0, time.UTC),
        AreaID:      1,
        Currency:    "JPY",
    }

    intervals := Explode(trade, comp)

    // 28 days × 48 half-hours = 1344
    expected := 28 * 48
    if len(intervals) != expected {
        t.Errorf("STANDARD: got %d intervals, want %d", len(intervals), expected)
    }
}

func TestExplode_ConstantProduct(t *testing.T) {
    trade := Trade{TradeID: 2, UniqueID: "TEST-002"}
    comp := TradeComponent{
        ComponentID: 2,
        ProductType: "CONSTANT",
        Quantity:    50.0,
        Price:       82.00,
        StartDate:   time.Date(2025, 2, 1, 0, 0, 0, 0, time.UTC),
        EndDate:     time.Date(2025, 2, 28, 0, 0, 0, 0, time.UTC),
        AreaID:      2,
        Currency:    "AUD",
    }

    intervals := Explode(trade, comp)

    // Weekdays only, 07:00-17:00 = 20 slots per day
    // Feb 2025 has 20 weekdays
    expected := 20 * 20
    if len(intervals) != expected {
        t.Errorf("CONSTANT: got %d intervals, want %d", len(intervals), expected)
    }

    // Verify no weekend slots
    for _, iv := range intervals {
        if iv.IntervalStart.Weekday() == time.Saturday || iv.IntervalStart.Weekday() == time.Sunday {
            t.Errorf("CONSTANT product should not include weekends, got %s", iv.IntervalStart)
        }
    }
}
```

Run tests: `go test ./internal/domain/ -v`

**Critical thinking:** Why is the weekday count 20 and not some other number? Open a calendar for Feb 2025 and count manually. This is the kind of off-by-one error that causes million-dollar P&L breaks.

---

## Part D — REST API (30 min)

### Task D1: Build the router

Create `internal/api/router.go`:

```go
package api

import (
    "github.com/gin-gonic/gin"
    "github.com/prometheus/client_golang/prometheus/promhttp"
)

func NewRouter(h *Handler) *gin.Engine {
    r := gin.Default()

    // Health & metrics
    r.GET("/health", func(c *gin.Context) { c.JSON(200, gin.H{"status": "ok"}) })
    r.GET("/metrics", gin.WrapH(promhttp.Handler()))

    // Trade endpoints
    api := r.Group("/api/v1")
    {
        api.POST("/trades", h.CreateTrade)
        api.GET("/trades", h.ListTrades)
        api.GET("/trades/:id", h.GetTrade)
        api.GET("/trades/:id/pnl", h.GetTradePnL)
        api.GET("/pnl/summary", h.GetPnLSummary)
    }

    return r
}
```

### Task D2: Implement the CreateTrade handler

This is the money handler. It must:
1. Validate the request
2. Check credit limit against MDM
3. Insert trade into MSSQL
4. Explode to intervals
5. Insert intervals into ClickHouse
6. Publish `trade.created` event to Kafka

Create `internal/api/handlers.go` — implement each step. Think about:
- What happens if MSSQL insert succeeds but ClickHouse insert fails? (inconsistency)
- What happens if you publish to Kafka before confirming the DB write? (phantom events)
- How do you make this idempotent? (use `unique_id` as dedup key)

---

## Part E — Wire It Together (20 min)

### Task E1: Create main.go

```go
package main

import (
    "log"
    "os"
    "os/signal"
    "syscall"
)

func main() {
    // Connect to MSSQL
    // Connect to ClickHouse
    // Connect to Kafka
    // Create handler
    // Start HTTP server on :8080
    // Wait for shutdown signal

    quit := make(chan os.Signal, 1)
    signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
    <-quit
    log.Println("Shutting down...")
}
```

### Task E2: Add a Dockerfile

```dockerfile
FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /trade-service ./cmd/server

FROM alpine:3.19
COPY --from=builder /trade-service /trade-service
EXPOSE 8080
CMD ["/trade-service"]
```

### Task E3: Add to docker-compose

Add the `trade-service` service to `docker-compose.yml` with connections to MSSQL, ClickHouse, and Kafka.

---

## Part F — Test the Full Pipeline (20 min)

### Task F1: Create a trade via API
```bash
curl -X POST http://localhost:8080/api/v1/trades \
  -H "Content-Type: application/json" \
  -d '{
    "unique_id": "TRADE-TEST-001",
    "counterparty_mdm_id": "MDM-001",
    "trader_id": 1,
    "book_id": 1,
    "components": [{
      "area_id": 1,
      "delivery_profile_id": 1,
      "settlement_mode": "FINANCIAL",
      "currency": "JPY",
      "product_type": "STANDARD",
      "quantity": 50.0,
      "price": 12.50,
      "start_date": "2025-05-01",
      "end_date": "2025-05-31"
    }]
  }'
```

### Task F2: Verify the data
1. Check MSSQL: `SELECT * FROM trade WHERE unique_id = 'TRADE-TEST-001'`
2. Check ClickHouse: `SELECT count(*) FROM etrm.transaction_exploded FINAL WHERE unique_id = 'TRADE-TEST-001'`
   - Expected: 31 days × 48 = 1,488 rows
3. Check Kafka: consume from `trade.events` and find your message
4. Check P&L: `GET http://localhost:8080/api/v1/trades/6/pnl`

---

## Checkpoint: What You Should Be Able to Do

- [ ] Explain the trade explosion algorithm and why the row count matters
- [ ] Build a REST API in Go that talks to MSSQL and ClickHouse
- [ ] Handle the dual-write problem (MSSQL + ClickHouse consistency)
- [ ] Publish events to Kafka after a successful write
- [ ] Write tests that verify interval counts for each product type
- [ ] Explain why `IssueDateTime` matters for every ClickHouse insert

---

## Reflection: What Makes This World-Class?

Most ETRM developers can write a CRUD endpoint. What separates world-class from average:

1. **Idempotency** — Can you call CreateTrade twice with the same `unique_id` and get the same result?
2. **Observability** — Every trade creation should emit a Prometheus counter + histogram for latency
3. **Graceful degradation** — If ClickHouse is down, can you still book the trade in MSSQL and catch up later?
4. **Testing edge cases** — What about a trade spanning a DST transition? A leap year? A trade starting at 23:30?
5. **Performance** — Can you insert 10,000 intervals in a single batch? ClickHouse native format is 100x faster than row-by-row.

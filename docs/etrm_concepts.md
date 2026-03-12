# ETRM Concepts — Trade Lifecycle End to End

This document explains the domain. Every section maps directly to tables or code in this sandbox.

---

## What an Energy Trading Firm Actually Does

A firm buys and sells electricity. They agree a price now for delivery in the future. Between now and delivery, the market price moves. The difference between what they agreed and what the market is worth now = their P&L.

**Simple example:**
- Jan 1: Firm agrees to SELL 100 MW in March at ¥15/kWh to counterparty ABC
- Feb 1: JEPX market price for March rises to ¥18/kWh
- The firm is now losing ¥3/kWh × 100 MW × all half-hour intervals in March
- This loss is **unrealized P&L** — the trade hasn't been delivered yet
- After March delivery, it becomes **realized P&L** — locked in

Your job as a developer: build the systems that track this accurately, in real time, across thousands of trades.

---

## The 5 Core Tables (MSSQL)

These are the "five tables that can be touched" — the source of truth for all trades.

```
counterparty ──┐
               ├──> trade ──> trade_component ──> delivery_profile
               │         └──> invoice
```

### 1. counterparty
Who the firm is trading with. Banks, utilities, other trading firms.

```
JERA (counterparty_id=1, credit_limit=5,000,000 JPY)
AGL Energy (counterparty_id=2, credit_limit=3,000,000 AUD)
Mercury NZ (counterparty_id=3, credit_limit=2,000,000 NZD)
```

**Credit limit** = maximum total open exposure allowed with this counterparty.
If a new trade would push exposure over the limit → reject the trade.

### 2. trade
The master record. One row per contract agreed with a counterparty.

Key fields to understand:
- `unique_id` — the business key (e.g. `TRD-2025-001`). What traders refer to.
- `trade_id` — internal database ID. Not shown to users.
- `counterparty_id` — who the trade is with
- `book_id` — which trading book this trade belongs to (desk, strategy)
- `is_hypothetical` — if 1, this is a what-if scenario, not a real trade
- `trade_at_utc` — when the trade was agreed (execution timestamp)

### 3. trade_component
The product details. One trade can have multiple components (e.g. physical delivery + financial hedge).

Key fields:
- `area_id` — which electricity market: `1=JEPX`, `2=NEM`, `3=NZEM`
- `settlement_mode` — `PHYSICAL` (actual power delivery) or `FINANCIAL` (cash only)
- `product_type` — `STANDARD`, `CONSTANT`, or `VARIABLE` (determines delivery schedule)
- `quantity` — MW (megawatts) per interval
- `price` — contracted price per MWh (or kWh for JEPX)
- `start_date` / `end_date` — delivery period

### 4. delivery_profile
Defines the schedule for CONSTANT and VARIABLE products.

| product_type | What it means | Example |
|---|---|---|
| STANDARD | Every hour, full day, 7 days a week | Base load for all of March |
| CONSTANT | Fixed daily window, every weekday | 7am-3pm business hours only |
| VARIABLE | Custom schedule defined in delivery_profile | Specific hours, excluding weekends/holidays |

**STANDARD** products don't need a delivery_profile — the schedule is implied (all 48 half-hour slots per day).

### 5. invoice
Generated after delivery. One invoice per trade per billing period.

Key fields:
- `amount` — what we calculated we're owed (or owe)
- `matched_amount` — what the counterparty says they owe us
- `match_status` — `FULL` (amounts match), `PARTIAL` (within tolerance), `MISMATCH` (flag for manual review)
- `status` — `PENDING`, `MATCHED`, `ERROR`

---

## Trade Explosion — MSSQL → ClickHouse

When a trade is created in MSSQL, the Go service "explodes" it into half-hour intervals in ClickHouse.

**Why?** Because P&L is calculated per half-hour slot. A 1-month trade for JEPX = 31 days × 48 slots = 1,488 rows in `transaction_exploded`.

```
trade (1 row in MSSQL)
  └── trade_component (1+ rows in MSSQL)
        └── transaction_exploded (hundreds of rows in ClickHouse)
              interval_start=2025-03-01 00:00, quantity=100, price=15.0, realized_pnl=null
              interval_start=2025-03-01 00:30, quantity=100, price=15.0, realized_pnl=null
              interval_start=2025-03-01 01:00, quantity=100, price=15.0, realized_pnl=null
              ... (1,488 rows total for a 31-day STANDARD product)
```

**STANDARD product explosion logic:**
```
for each day in [start_date, end_date]:
    for each 30-min slot in that day (48 slots):
        insert row: (trade_id, interval_start, interval_end, quantity, price)
```

**CONSTANT product explosion logic:**
```
for each weekday in [start_date, end_date]:
    for each 30-min slot between start_time and end_time:
        insert row: (trade_id, interval_start, interval_end, quantity, price)
```

---

## P&L Lifecycle

A trade's P&L changes over time as market prices update and delivery happens.

### Stage 1: Trade Created (all intervals in the future)
```
interval_start=2025-03-01 00:00
  settle_price = NULL         (not delivered yet)
  mtm_price = 16.50           (current market estimate)
  unrealized_pnl = (16.50 - 15.0) * 100 = +150.0  (we sold at 15, market is 16.50 → we're losing)
  realized_pnl = NULL
```

### Stage 2: Market Price Moves
```
interval_start=2025-03-01 00:00
  mtm_price = 14.20           (market dropped — now we're in the money)
  unrealized_pnl = (14.20 - 15.0) * 100 = -80.0  (we sold at 15, market is 14.20 → we're winning)
```
**How this works in ClickHouse:** A new row is inserted with the updated `mtm_price` and `issue_datetime`. The old row still exists. `FINAL` or `argMax` returns the latest row.

### Stage 3: Interval Delivered (settle price published by exchange)
```
interval_start=2025-03-01 00:00
  settle_price = 13.80        (actual settlement price from JEPX)
  realized_pnl = (13.80 - 15.0) * 100 = -120.0
  unrealized_pnl = NULL       (no longer relevant — it's settled)
```

### Stage 4: Invoice Generated
```
invoice:
  trade_id = 1
  amount = SUM(realized_pnl) for March = total what we owe/are owed
  status = PENDING
```

### Stage 5: Invoice Matched
```
invoice:
  matched_amount = what counterparty says
  match_status = FULL / PARTIAL / MISMATCH
  status = MATCHED / ERROR
```

---

## Settlement: Physical vs Financial

### PHYSICAL settlement
Actual electrons delivered to the grid.
- BUY: you receive power from the grid, pay at settle_price
- SELL: you deliver power to the grid, receive settle_price
- **Critical:** Your BUY quantity must equal your SELL quantity each interval. If not → **imbalance charge** from the grid operator.

```
Interval 00:00-00:30:
  Trade A: SELL 100 MW at ¥15 → receive 100 × ¥(settle) from grid
  Trade B: BUY  80 MW at ¥14 → pay    80 × ¥(settle) to grid
  Net position: SELL 20 MW
  Imbalance: 20 MW — grid operator charges you for this deviation
```

### FINANCIAL settlement
Cash only. No physical delivery.
- Both parties calculate what they would have paid/received at market prices
- Net difference is paid in cash
- No imbalance risk — nothing physically changes hands

---

## Mark-to-Market (MTM)

MTM = "if I closed this trade right now at current market prices, what would I get?"

**Two sources of MTM price:**
1. **Exchange MTM** — price published daily by JEPX/AEMO/Transpower for each future interval
2. **In-house model (mark-to-model)** — quant team's proprietary curve when exchange data is unavailable

In ClickHouse:
- Exchange prices stored in `market_data` table
- MTM curves (both exchange and model) stored in `mtm_curve` table
- `transaction_exploded.mtm_price` is populated from these curves by the Go service

The `COALESCE(settle_price, mtm_price)` pattern:
- If `settle_price` is set → interval is settled, use it
- If `settle_price` is NULL → interval is open, use `mtm_price` for current estimate

---

## Credit Risk

Before a trade is accepted, the system checks:

```
current_exposure = SUM(quantity * price) for all open trades with counterparty X
new_trade_value  = new_trade quantity * price * delivery_days

if current_exposure + new_trade_value > credit_limit:
    REJECT trade
```

**Why it matters:** If a counterparty defaults, you lose all open trade value with them. The credit limit is your maximum acceptable loss.

**Credit limit in sandbox:** Set on the `counterparty` table. Currently `2,000,000` for all three counterparties (in their respective currencies).

---

## Market Areas

| area_id | Market | Country | Currency | Interval | Exchange |
|---|---|---|---|---|---|
| 1 | JEPX | Japan | JPY | 30 min | Japan Electric Power Exchange |
| 2 | NEM | Australia | AUD | 30 min | National Electricity Market (AEMO) |
| 3 | NZEM | New Zealand | NZD | 30 min | NZ Electricity Market (Transpower) |

**All three use 30-minute intervals** — which is why `half_hour_intervals` is the common time dimension.

**Price units differ:**
- JEPX: ¥/kWh (yen per kilowatt-hour) — multiply by 1000 to get per-MWh
- NEM: AUD/MWh (dollars per megawatt-hour)
- NZEM: NZD/MWh (dollars per megawatt-hour)

---

## What a Typical Day Looks Like (On the Job)

**Morning:**
1. Settlement prices from previous day are published by the exchanges (~7am)
2. Go service ingests them → updates `transaction_exploded` with `settle_price`
3. P&L engine runs → calculates `realized_pnl` for all yesterday's intervals
4. Traders open Superset/Power BI → check yesterday's realized P&L

**Throughout the day:**
1. Market prices update every 30 minutes
2. Go service ingests → updates `mtm_price` in `transaction_exploded`
3. Unrealized P&L recalculates automatically
4. Risk desk monitors exposure dashboard

**New trade comes in:**
1. Trader agrees a deal with counterparty
2. Trade captured in system via API or front-end
3. Credit check runs automatically
4. Trade exploded to ClickHouse
5. Immediately visible in Superset dashboards

**End of month:**
1. Settlement runner generates invoices for all delivered trades
2. Invoice matching compares our invoice vs counterparty's invoice
3. Any MISMATCH flags go to ops team for manual review
4. Finance reconciles invoices for payment

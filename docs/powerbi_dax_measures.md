# Power BI DAX Measures — ETRM Sandbox

These are ready-to-use DAX measures. In Power BI Desktop, go to the table you want
to add the measure to → **Table tools → New measure** → paste the formula.

---

## P&L Measures (add to `vw_pnl_by_trade` table)

```dax
-- Total realized P&L across selected filters
Total Realized PnL =
SUM(vw_pnl_by_trade[total_realized_pnl])

-- Total unrealized P&L
Total Unrealized PnL =
SUM(vw_pnl_by_trade[total_unrealized_pnl])

-- Combined P&L (what traders see as "the number")
Total PnL =
[Total Realized PnL] + [Total Unrealized PnL]

-- P&L formatted with currency sign (assumes single currency filter)
Total PnL Formatted =
FORMAT([Total PnL], "#,##0.00")

-- % of P&L that is realized (shows how much of the book has settled)
Realized PnL % =
DIVIDE(
    [Total Realized PnL],
    [Total PnL],
    0
)

-- Average P&L per trade
Avg PnL Per Trade =
DIVIDE(
    [Total PnL],
    DISTINCTCOUNT(vw_pnl_by_trade[trade_id]),
    0
)

-- Count of profitable trades
Profitable Trades =
CALCULATE(
    DISTINCTCOUNT(vw_pnl_by_trade[trade_id]),
    vw_pnl_by_trade[total_pnl] > 0
)

-- Count of loss-making trades
Loss Trades =
CALCULATE(
    DISTINCTCOUNT(vw_pnl_by_trade[trade_id]),
    vw_pnl_by_trade[total_pnl] < 0
)

-- Win rate %
Win Rate % =
DIVIDE(
    [Profitable Trades],
    [Profitable Trades] + [Loss Trades],
    0
)
```

---

## Daily P&L Measures (add to `vw_pnl_daily` table)

```dax
-- Cumulative P&L over time (for running total line chart)
Cumulative PnL =
CALCULATE(
    SUM(vw_pnl_daily[daily_total_pnl]),
    FILTER(
        ALL(vw_pnl_daily[delivery_date]),
        vw_pnl_daily[delivery_date] <= MAX(vw_pnl_daily[delivery_date])
    )
)

-- Day-over-day P&L change
PnL Daily Change =
VAR CurrentDay = SUM(vw_pnl_daily[daily_total_pnl])
VAR PrevDay =
    CALCULATE(
        SUM(vw_pnl_daily[daily_total_pnl]),
        DATEADD(vw_pnl_daily[delivery_date], -1, DAY)
    )
RETURN CurrentDay - PrevDay

-- Best single day
Best Day PnL =
MAXX(
    VALUES(vw_pnl_daily[delivery_date]),
    CALCULATE(SUM(vw_pnl_daily[daily_total_pnl]))
)

-- Worst single day
Worst Day PnL =
MINX(
    VALUES(vw_pnl_daily[delivery_date]),
    CALCULATE(SUM(vw_pnl_daily[daily_total_pnl]))
)
```

---

## Credit & Exposure Measures (add to `vw_counterparty_exposure` table)

```dax
-- Total exposure across all counterparties
Total Exposure =
SUM(vw_counterparty_exposure[total_exposure])

-- Total credit limit headroom
Total Headroom =
SUM(vw_counterparty_exposure[remaining_headroom])

-- Portfolio-level utilisation %
Portfolio Utilisation % =
DIVIDE(
    [Total Exposure],
    SUM(vw_counterparty_exposure[credit_limit]),
    0
)

-- Count of counterparties near limit (>80% utilised)
Counterparties Near Limit =
CALCULATE(
    COUNTROWS(vw_counterparty_exposure),
    vw_counterparty_exposure[utilisation_pct] >= 80
)

-- Flag: any counterparty over limit?
Any Over Limit =
IF(
    CALCULATE(
        COUNTROWS(vw_counterparty_exposure),
        vw_counterparty_exposure[utilisation_pct] > 100
    ) > 0,
    "⚠️ BREACH",
    "OK"
)
```

---

## Invoice Measures (add to `vw_invoice_status` table)

```dax
-- Total invoice value
Total Invoice Amount =
SUM(vw_invoice_status[amount])

-- Total matched amount
Total Matched Amount =
SUM(vw_invoice_status[matched_amount])

-- Unmatched / outstanding amount
Total Unmatched =
SUM(vw_invoice_status[unmatched_amount])

-- Match rate %
Invoice Match Rate % =
DIVIDE(
    [Total Matched Amount],
    [Total Invoice Amount],
    0
)

-- Count by status
Pending Invoices =
CALCULATE(COUNTROWS(vw_invoice_status), vw_invoice_status[status] = "PENDING")

Matched Invoices =
CALCULATE(COUNTROWS(vw_invoice_status), vw_invoice_status[status] = "MATCHED")

Error Invoices =
CALCULATE(COUNTROWS(vw_invoice_status), vw_invoice_status[status] = "ERROR")

-- Overdue invoices (past due date)
Overdue Invoices =
CALCULATE(
    COUNTROWS(vw_invoice_status),
    vw_invoice_status[days_overdue] > 0,
    vw_invoice_status[status] <> "MATCHED"
)

-- Total overdue amount
Overdue Amount =
CALCULATE(
    SUM(vw_invoice_status[unmatched_amount]),
    vw_invoice_status[days_overdue] > 0,
    vw_invoice_status[status] <> "MATCHED"
)
```

---

## Trade Blotter Measures (add to `vw_trade_blotter` table)

```dax
-- Total number of active trades
Active Trade Count =
CALCULATE(
    DISTINCTCOUNT(vw_trade_blotter[trade_id]),
    vw_trade_blotter[is_active] = TRUE()
)

-- Total notional across all active trades
Total Notional =
CALCULATE(
    SUM(vw_trade_blotter[notional_value]),
    vw_trade_blotter[is_active] = TRUE()
)

-- Total MW on book
Total MW =
CALCULATE(
    SUM(vw_trade_blotter[quantity_mw]),
    vw_trade_blotter[is_active] = TRUE()
)

-- Physical vs Financial split %
Physical Trade % =
DIVIDE(
    CALCULATE(
        COUNTROWS(vw_trade_blotter),
        vw_trade_blotter[settlement_mode] = "PHYSICAL"
    ),
    COUNTROWS(vw_trade_blotter),
    0
)

-- Average contracted price (weighted by quantity)
Weighted Avg Price =
DIVIDE(
    SUMX(
        vw_trade_blotter,
        vw_trade_blotter[quantity_mw] * vw_trade_blotter[contracted_price]
    ),
    SUM(vw_trade_blotter[quantity_mw]),
    0
)
```

---

## Market Price Measures (add to `vw_market_prices_latest` table)

```dax
-- Latest price for selected area/date filter
Latest Price =
CALCULATE(
    LASTNONBLANK(vw_market_prices_latest[latest_price], 1),
    LASTDATE(vw_market_prices_latest[value_datetime])
)

-- Price vs previous period (useful for showing direction)
Price Change =
VAR Latest = [Latest Price]
VAR Previous =
    CALCULATE(
        [Latest Price],
        DATEADD(vw_market_prices_latest[value_date], -1, DAY)
    )
RETURN Latest - Previous

-- Price direction label for conditional formatting
Price Direction =
IF([Price Change] > 0, "▲", IF([Price Change] < 0, "▼", "─"))
```

---

## Tips for Using These in Power BI

1. **Card visuals** — use single-value measures like `Total PnL`, `Total Notional`, `Invoice Match Rate %`
2. **KPI visuals** — use `Total PnL` as value, `Cumulative PnL` as trend, set a target
3. **Conditional formatting** — on tables, use `utilisation_pct` or `days_overdue` to colour cells red/amber/green
4. **Slicers** — always add `market_area`, `currency`, and a date range slicer so traders can filter to their book
5. **Drill-through** — set `vw_trade_intervals_flat` as a drill-through page so traders can click a trade and see every half-hour slot

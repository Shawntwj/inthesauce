# Lab 3 — Superset: Build a Business Report from Scratch

**Prereqs:** Lab 1 complete. Superset running at localhost:8088.
**Time:** 45-60 minutes
**Goal:** Build a real business report end to end — the way you'd do it when a trader asks.

---

## Scenario

A trader pings you:

> "Can you put together a quick view showing:
> - Our total open MW by market
> - Which counterparties we're most exposed to
> - Current market prices for JEPX, NEM, NZEM
> I need it by EOD."

You have the data. You're going to build this in Superset in under an hour.

---

## Part A — Explore the Data First (10 min)

Always explore before you build.

### Task A1: Check what data is available
Open SQL Lab → ETRM MSSQL:
```sql
-- What trades do we have?
SELECT
    CASE tc.area_id WHEN 1 THEN 'JEPX' WHEN 2 THEN 'NEM' WHEN 3 THEN 'NZEM' END AS market,
    tc.settlement_mode,
    COUNT(*) AS trade_count,
    SUM(tc.quantity) AS total_mw
FROM trade t
JOIN trade_component tc ON tc.trade_id = t.trade_id
WHERE t.is_active = 1
GROUP BY tc.area_id, tc.settlement_mode;
```

Switch to ETRM ClickHouse:
```sql
-- Current market prices
SELECT market_area, latest_price, currency, as_of
FROM etrm.vw_market_prices_latest
WHERE value_date = today()
GROUP BY market_area, latest_price, currency, as_of;
```

Note what data you have. If no prices show for today, use:
```sql
SELECT market_area, latest_price, currency, max(as_of) AS as_of
FROM etrm.vw_market_prices_latest
GROUP BY market_area, latest_price, currency
LIMIT 3;
```

---

## Part B — Build the Charts (25 min)

Go to **Charts → + Chart**.

### Chart 1: Open MW by Market Area (Bar chart)
- **Dataset:** trade_component (ETRM MSSQL)
- **Chart type:** Bar Chart
- **X-axis / Dimension:** `area_id`
- **Metric:** SUM of `quantity`
- **Title:** "Open Volume (MW) by Market"
- Save it

### Chart 2: Exposure by Counterparty (Pie chart)
- **Dataset:** `vw_trade_blotter` (ETRM MSSQL) — this view already joins counterparty names
- **Chart type:** Pie Chart
- **Dimension:** `counterparty_name` (NOT `counterparty_id` — numeric IDs are meaningless to traders)
- **Metric:** SUM of `notional_value`
- **Title:** "Notional Exposure by Counterparty"
- Save it

> **Tip:** If a dataset only has `counterparty_id`, you need a view or SQL query that JOINs to the `counterparty` table. Never show raw IDs in a business report — always show names.

### Chart 3: Current Market Prices (Big Numbers — one per market)
Create 3 separate **Big Number** charts:

**Chart 3a — JEPX price:**
- Dataset: `vw_market_prices_latest` (ETRM ClickHouse)
- Chart type: Big Number with Trendline
- Metric: AVG of `latest_price`
- Filters: `market_area = JEPX`
- Title: "JEPX Spot Price (JPY)"

**Chart 3b — NEM price:**
- Same but filter `market_area = NEM`
- Title: "NEM Spot Price (AUD)"

**Chart 3c — NZEM price:**
- Same but filter `market_area = NZEM`
- Title: "NZEM Spot Price (NZD)"

### Chart 4: Price Trend Over Time (Line chart)
- **Dataset:** `vw_market_prices_latest` (ETRM ClickHouse)
- **Chart type:** Line Chart (time series)
- **X-axis:** `value_datetime`
- **Metric:** AVG of `latest_price`
- **Breakdown by:** `market_area`
- **Title:** "Market Price Trends"
- Save it

---

## Part C — Assemble the Dashboard (10 min)

Go to **Dashboards → + Dashboard**.

1. Name it: "Trader Morning View"
2. Click **Edit dashboard**
3. Drag your 6 charts onto the canvas:

Suggested layout:
```
[ JEPX Price ] [ NEM Price ] [ NZEM Price ]    ← Row 1: KPI tiles
[ Price Trend (full width)               ]    ← Row 2: trend line
[ Open MW by Market ] [ Exposure by Cpty ]    ← Row 3: two charts
```

4. Resize charts by dragging their corners
5. Click **Save** → **Publish**

---

## Part D — Add a Filter (5 min)

Add a filter so the trader can slice by market area.

1. In the dashboard, click **Filters** (top right) → **+ Add filter**
2. Type: **Value**
3. Column: `market_area` (from vw_market_prices_latest dataset)
4. Check: **Apply to all panels**
5. Save

Now test: select "JEPX" in the filter — all charts should update to show only JEPX data.

---

## Part E — Share It (5 min)

1. Click the **share** icon (top right of dashboard)
2. Copy the URL
3. Open it in an incognito window — you can see it without logging in if the dashboard is published

In a real firm, you'd share this URL with the trader or embed it in their internal portal.

---

## Extension Tasks (if you finish early)

### Extension 1: Add a table of all trades
- Add a **Table** chart using the `trade` dataset (MSSQL)
- Columns: `unique_id`, `counterparty_id`, `is_active`, `trade_at_utc`
- Add to the dashboard

### Extension 2: Build the same dashboard in SQL Lab
Write a single SQL query that produces the same data as your "Open MW by Market" chart, without using the Superset chart builder. Can you do it in one query?

### Extension 3: Schedule the dashboard
Go to **Settings → Alerts & Reports → + Report**
- Dashboard: Trader Morning View
- Schedule: daily at 8am
- Recipients: your email
(Note: requires email config in Superset — skip if not set up)

---

## Checkpoint: What You Should Be Able to Do

- [ ] Find data in SQL Lab before building a chart
- [ ] Create a bar chart, pie chart, big number, and line chart from scratch
- [ ] Assemble charts into a dashboard with sensible layout
- [ ] Add a filter that applies across all charts
- [ ] Explain to someone else what each chart shows and why

---

## Reflection Questions

After completing the lab, think through:

1. **A trader asks:** "Why does the JEPX price show ¥15.50 but yesterday it was ¥14.20?"
   - How would you check what changed? (Hint: `issue_datetime` in ClickHouse)

2. **A risk manager asks:** "I need this same data in Excel."
   - How would you export it? (Superset: download CSV from any chart)
   - How would Power BI handle this differently? (DirectQuery = always live, no export needed)

3. **The data is wrong:** A trade shows area_id=1 but the trader says it's NEM.
   - Where would you go to fix it? (MSSQL — update the `trade_component` row)
   - What happens to the Superset chart after the fix? (Refreshes on next query — automatic)

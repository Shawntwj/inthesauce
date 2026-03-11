# Power BI Setup Guide — ETRM Sandbox

This guide covers setting up Power BI Desktop on a Windows VM (on Mac) and connecting it to the ETRM Docker stack.

---

## Part 1: Windows VM Setup (one-time)

### 1.1 Install VMware Fusion
1. Go to [broadcom.com](https://www.broadcom.com) → create a free account
2. Search for **VMware Fusion 13** under "My Downloads"
3. Download and install — free for personal use

### 1.2 Get Windows 11 ARM ISO (easiest method)
1. Download **CrystalFetch** from the Mac App Store (free)
2. Open CrystalFetch → select **Windows 11** → **ARM64**
3. Click Download — it fetches the official Microsoft ISO directly
4. Save the `.iso` file somewhere easy to find (e.g. `~/Downloads/`)

### 1.3 Create the VM
1. Open VMware Fusion → **File → New**
2. Drag the Windows 11 ARM ISO into the window
3. Recommended settings:
   - RAM: **8 GB** (4 GB minimum)
   - Disk: **60 GB**
   - CPU: **4 cores**
4. Install Windows — skip the product key (runs as evaluation, valid 90 days, renewable)
5. Skip Microsoft account sign-in if prompted (use offline account)

### 1.4 Install Power BI Desktop
1. Inside the Windows VM, open Microsoft Store
2. Search **Power BI Desktop** → Install (free)
3. Or download directly from: https://powerbi.microsoft.com/desktop

---

## Part 2: Connecting Power BI to MSSQL

MSSQL runs in Docker on your Mac. From inside the VM, use `host.docker.internal` instead of `localhost`.

### 2.1 Connection Details
| Field | Value |
|---|---|
| Server | `host.docker.internal,1433` |
| Database | `etrm` |
| Authentication | SQL Server Authentication |
| Username | `sa` |
| Password | `YourStr0ngPass1` (or whatever is in your `.env`) |

### 2.2 Steps in Power BI Desktop
1. **Home → Get Data → SQL Server**
2. Server: `host.docker.internal,1433`
3. Database: `etrm`
4. Data Connectivity mode: **Import** (recommended for learning)
5. Click OK → enter credentials (Database tab, SQL Server auth)
6. In the Navigator, select these views:
   - `dbo.vw_trade_blotter`
   - `dbo.vw_counterparty_exposure`
   - `dbo.vw_invoice_status`
   - `dbo.vw_book_summary`
7. Click **Load**

> **Note:** If `host.docker.internal` doesn't resolve, use your Mac's IP address on the VMware network. Find it by running `ipconfig` inside Windows and looking for the VMware adapter IP, then replacing last octet with `.1`.

---

## Part 3: Connecting Power BI to ClickHouse

ClickHouse requires an ODBC driver. Power BI can then use it via **ODBC connector**.

### 3.1 Install ClickHouse ODBC Driver (inside Windows VM)
1. Go to: https://github.com/ClickHouse/clickhouse-odbc/releases
2. Download the latest **Windows x64** installer: `clickhouse-odbc-*-win64.msi`
3. Run the installer — accept defaults

### 3.2 Configure ODBC Data Source
1. Open **ODBC Data Sources (64-bit)** from Windows Start menu
2. Click **Add** → select **ClickHouse Unicode** → Finish
3. Fill in:
   | Field | Value |
   |---|---|
   | Data Source Name | `ETRM_ClickHouse` |
   | Host | `host.docker.internal` |
   | Port | `8123` |
   | Database | `etrm` |
   | Username | `default` |
   | Password | *(leave blank)* |
4. Click **Test Connection** — should say "Connected successfully"
5. Click OK to save

### 3.3 Connect in Power BI Desktop
1. **Home → Get Data → ODBC**
2. Select **ETRM_ClickHouse** from the dropdown
3. Click OK (no credentials needed — ClickHouse default user has no password)
4. In the Navigator, select these views:
   - `etrm.vw_pnl_by_trade`
   - `etrm.vw_pnl_daily`
   - `etrm.vw_market_prices_latest`
   - `etrm.vw_mtm_curve_latest`
   - `etrm.vw_trade_intervals_flat`
5. Click **Load**

---

## Part 4: Data Model in Power BI

After loading all tables, set up these relationships in **Model view**:

```
vw_trade_blotter          ──(trade_id)──►  vw_pnl_by_trade
vw_trade_blotter          ──(trade_id)──►  vw_invoice_status
vw_trade_blotter          ──(trade_id)──►  vw_trade_intervals_flat
vw_counterparty_exposure  ──(counterparty_id)──►  vw_trade_blotter
vw_market_prices_latest   ──(area_id)──►  vw_trade_blotter
```

**Steps:**
1. Go to **Model view** (icon on left sidebar)
2. Drag `trade_id` from `vw_trade_blotter` to `trade_id` in `vw_pnl_by_trade`
3. Repeat for the other relationships above
4. Set all relationships to **Many-to-one (*)→1** with single cross-filter direction

---

## Part 5: Suggested Report Pages

### Page 1 — Trade Blotter
- **Table visual**: `vw_trade_blotter` — columns: trade_ref, trade_date, counterparty_name, market_area, settlement_mode, quantity_mw, contracted_price, notional_value, delivery_start, delivery_end
- **Slicer**: market_area, settlement_mode, book_id
- **Card visuals**: Total trades, Total notional value

### Page 2 — P&L Dashboard
- **Bar chart**: total_realized_pnl + total_unrealized_pnl by trade_ref (from `vw_pnl_by_trade`)
- **Line chart**: daily_total_pnl over delivery_date by market_area (from `vw_pnl_daily`)
- **Matrix**: trade_ref × market_area with total_pnl values
- **Slicer**: currency, market_area, date range

### Page 3 — Market Prices
- **Line chart**: latest_price over value_datetime, one line per market_area (from `vw_market_prices_latest`)
- **Slicer**: market_area, date range
- **Card**: Latest JEPX / NEM / NZEM price

### Page 4 — Credit & Exposure
- **Gauge visual**: utilisation_pct per counterparty (from `vw_counterparty_exposure`)
- **Bar chart**: total_exposure vs credit_limit by counterparty_name
- **Table**: counterparty_name, open_trade_count, total_exposure, remaining_headroom

### Page 5 — Invoice Matching
- **Donut chart**: count by status (PENDING / MATCHED / ERROR) (from `vw_invoice_status`)
- **Table**: invoice_number, trade_ref, counterparty_name, amount, matched_amount, match_status, days_overdue
- **Conditional formatting**: highlight rows where match_status = 'MISMATCH' in red

---

## Part 6: Run the Views

Before connecting Power BI, make sure the views exist in both databases.

### MSSQL views
Connect to MSSQL with DBeaver or sqlcmd and run:
```bash
# From your Mac terminal (sqlcmd via Docker):
docker exec -i etrm-mssql /opt/mssql-tools/bin/sqlcmd \
  -S localhost -U sa -P 'YourStr0ngPass1' \
  -i /dev/stdin < scripts/powerbi_views_mssql.sql
```

### ClickHouse views
```bash
# From your Mac terminal:
curl -X POST 'http://localhost:8123' \
  --data-binary @scripts/powerbi_views_clickhouse.sql
```

Or use the Makefile shortcut (add these targets — see below):
```bash
make powerbi-views
```

---

## Troubleshooting

| Problem | Fix |
|---|---|
| Can't connect to `host.docker.internal` from VM | Try your Mac's VMware network IP (run `ipconfig` in Windows, look for VMware adapter gateway) |
| MSSQL login failed | Check `.env` for `MSSQL_SA_PASSWORD`, use that exact value |
| ClickHouse ODBC test fails | Make sure Docker is running on Mac first: `docker ps` |
| Power BI shows no data in views | Run the view creation scripts first (Part 6 above) |
| `transaction_exploded` view is empty | The Go service hasn't inserted any trade explosions yet — run the seed or ingest a trade |

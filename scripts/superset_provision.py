#!/usr/bin/env python3
"""
Superset Dashboard Provisioner — ETRM Sandbox
Run inside the Superset container:
  docker exec etrm-superset python3 /superset_provision.py

Uses requests (pre-installed in Superset image) with a session so
cookies + CSRF are handled automatically.
"""

import json, sys
import requests

BASE = "http://127.0.0.1:8088"
s = requests.Session()

def login():
    r = s.post(f"{BASE}/api/v1/security/login", json={
        "username": "admin", "password": "admin",
        "provider": "db", "refresh": True
    })
    token = r.json().get("access_token")
    if not token:
        print("ERROR: Login failed:", r.text[:200])
        sys.exit(1)
    s.headers.update({"Authorization": f"Bearer {token}"})
    # Get CSRF token (cookie-based session needed for mutating requests)
    r2 = s.get(f"{BASE}/api/v1/security/csrf_token/")
    csrf = r2.json().get("result", "")
    s.headers.update({"X-CSRFToken": csrf, "Referer": BASE})
    print(f"✓ Logged in (csrf={csrf[:16]}...)")

def find_db(name):
    r = s.get(f"{BASE}/api/v1/database/")
    for db in r.json().get("result", []):
        if db["database_name"] == name:
            return db["id"]
    return None

def upsert_dataset(db_id, table_name, schema):
    # Check if already exists
    r = s.get(f"{BASE}/api/v1/dataset/", params={"q": json.dumps({
        "filters": [{"col": "table_name", "opr": "eq", "val": table_name}]
    })})
    for ds in r.json().get("result", []):
        if ds["table_name"] == table_name and ds["database"]["id"] == db_id:
            print(f"  ~ Dataset '{table_name}' exists → id={ds['id']}")
            return ds["id"]

    r = s.post(f"{BASE}/api/v1/dataset/", json={
        "database": db_id,
        "schema": schema,
        "table_name": table_name,
        "always_filter_main_dttm": False,
    })
    if r.status_code in (200, 201):
        ds_id = r.json().get("id")
        print(f"  ✓ Dataset '{table_name}' created → id={ds_id}")
        return ds_id
    else:
        print(f"  [ERR] Dataset '{table_name}': {r.status_code} {r.text[:200]}")
        return None

def create_chart(name, viz, ds_id, params):
    r = s.post(f"{BASE}/api/v1/chart/", json={
        "slice_name": name,
        "viz_type": viz,
        "datasource_id": ds_id,
        "datasource_type": "table",
        "params": json.dumps(params),
    })
    if r.status_code in (200, 201):
        cid = r.json().get("id")
        print(f"  ✓ Chart '{name}' → id={cid}")
        return cid
    else:
        print(f"  [ERR] Chart '{name}': {r.status_code} {r.text[:300]}")
        return None

def create_dashboard(title, chart_ids):
    # Build grid layout
    positions = {
        "DASHBOARD_VERSION_KEY": "v2",
        "ROOT_ID": {"type": "ROOT", "id": "ROOT_ID", "children": ["GRID_ID"]},
        "GRID_ID": {"type": "GRID", "id": "GRID_ID", "children": [], "parents": ["ROOT_ID"]},
    }
    for i, cid in enumerate(chart_ids):
        if not cid: continue
        row_id = f"ROW-{i // 2}"
        chart_key = f"CHART-{cid}"
        if row_id not in positions:
            positions[row_id] = {"type": "ROW", "id": row_id, "children": [],
                                 "parents": ["ROOT_ID", "GRID_ID"],
                                 "meta": {"background": "BACKGROUND_TRANSPARENT"}}
            positions["GRID_ID"]["children"].append(row_id)
        positions[chart_key] = {
            "type": "CHART", "id": chart_key, "children": [],
            "parents": ["ROOT_ID", "GRID_ID", row_id],
            "meta": {"chartId": cid, "width": 6, "height": 50}
        }
        positions[row_id]["children"].append(chart_key)

    r = s.post(f"{BASE}/api/v1/dashboard/", json={
        "dashboard_title": title,
        "published": True,
        "position_json": json.dumps(positions),
        "slices": [{"id": cid} for cid in chart_ids if cid],
    })
    if r.status_code in (200, 201):
        did = r.json().get("id")
        print(f"  ✓ Dashboard '{title}' → id={did}  →  {BASE}/superset/dashboard/{did}/")
        return did
    else:
        print(f"  [ERR] Dashboard '{title}': {r.status_code} {r.text[:300]}")
        return None


def main():
    print("\n=== ETRM Superset Provisioner ===\n")
    login()

    ch_id = find_db("ETRM ClickHouse")
    ms_id = find_db("ETRM MSSQL")
    print(f"✓ ClickHouse id={ch_id}  MSSQL id={ms_id}\n")

    print("--- Datasets ---")
    ds_prices    = upsert_dataset(ch_id, "vw_market_prices_latest", "etrm")
    ds_mtm       = upsert_dataset(ch_id, "vw_mtm_curve_latest",     "etrm")
    ds_pnl       = upsert_dataset(ch_id, "vw_pnl_by_trade",         "etrm")
    ds_pnl_daily = upsert_dataset(ch_id, "vw_pnl_daily",            "etrm")
    ds_trade     = upsert_dataset(ms_id, "trade",                   "dbo")
    ds_cpty      = upsert_dataset(ms_id, "counterparty",            "dbo")
    ds_invoice   = upsert_dataset(ms_id, "invoice",                 "dbo")
    print()

    print("--- Charts ---")
    metric_avg = lambda col, lbl: {"expressionType":"SIMPLE","column":{"column_name":col},"aggregate":"AVG","label":lbl}
    metric_sum = lambda col, lbl: {"expressionType":"SIMPLE","column":{"column_name":col},"aggregate":"SUM","label":lbl}
    metric_cnt = lambda col, lbl: {"expressionType":"SIMPLE","column":{"column_name":col},"aggregate":"COUNT","label":lbl}

    c1 = create_chart("Market Prices by Area", "echarts_timeseries_line", ds_prices, {
        "viz_type": "echarts_timeseries_line",
        "x_axis": "value_datetime",
        "metrics": [metric_avg("latest_price", "Avg Price")],
        "groupby": ["market_area"],
        "time_range": "No filter",
        "rich_tooltip": True, "show_legend": True,
        "x_axis_title": "Date", "y_axis_title": "Price",
    })
    c2 = create_chart("Avg Price by Market Area", "echarts_bar", ds_prices, {
        "viz_type": "echarts_bar",
        "metrics": [metric_avg("latest_price", "Avg Price")],
        "groupby": ["market_area"],
        "time_range": "No filter",
        "show_legend": False,
    })
    c3 = create_chart("MTM Forward Curve", "echarts_timeseries_line", ds_mtm, {
        "viz_type": "echarts_timeseries_line",
        "x_axis": "value_datetime",
        "metrics": [metric_avg("mtm_price", "MTM Price")],
        "groupby": ["curve_id"],
        "time_range": "No filter",
        "show_legend": True,
        "x_axis_title": "Date", "y_axis_title": "MTM Price",
    })
    c4 = create_chart("Volume by Market Area", "echarts_area", ds_prices, {
        "viz_type": "echarts_area",
        "x_axis": "value_date",
        "metrics": [metric_sum("latest_volume", "Volume")],
        "groupby": ["market_area"],
        "time_range": "No filter",
        "show_legend": True,
    })
    c5 = create_chart("Total Active Trades", "big_number_total", ds_trade, {
        "viz_type": "big_number_total",
        "metric": metric_cnt("trade_id", "Trades"),
        "subheader": "Active trades on book",
        "time_range": "No filter",
    })
    c6 = create_chart("Active Counterparties", "big_number_total", ds_cpty, {
        "viz_type": "big_number_total",
        "metric": metric_cnt("counterparty_id", "Counterparties"),
        "subheader": "Registered counterparties",
        "time_range": "No filter",
    })
    c7 = create_chart("Trades by Counterparty", "pie", ds_trade, {
        "viz_type": "pie",
        "metric": metric_cnt("trade_id", "Trade Count"),
        "groupby": ["counterparty_id"],
        "time_range": "No filter",
        "show_legend": True, "show_labels": True,
    })
    c8 = create_chart("Invoice Status Breakdown", "pie", ds_invoice, {
        "viz_type": "pie",
        "metric": metric_cnt("invoice_id", "Count"),
        "groupby": ["status"],
        "time_range": "No filter",
        "show_legend": True, "show_labels": True, "label_type": "key_percent",
    })
    print()

    print("--- Dashboards ---")
    create_dashboard("ETRM — Market Data",              [c1, c2, c3, c4])
    create_dashboard("ETRM — Trade & Invoice Overview", [c5, c6, c7, c8])
    print()
    print("=== Done! Open http://localhost:8088/dashboard/list ===")

if __name__ == "__main__":
    main()

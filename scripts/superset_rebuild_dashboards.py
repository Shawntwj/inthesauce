"""
Superset Dashboard Rebuilder
Deletes all existing dashboards and rebuilds Market Data + Trade Book dashboards.
"""
import requests, json, uuid, sys

BASE = 'http://127.0.0.1:8088'
s = requests.Session()

# Auth
r = s.post(f'{BASE}/api/v1/security/login', json={
    'username': 'admin', 'password': 'admin', 'provider': 'db', 'refresh': True
})
r.raise_for_status()
token = r.json()['access_token']
s.headers['Authorization'] = f'Bearer {token}'
csrf = s.get(f'{BASE}/api/v1/security/csrf_token/').json()['result']
s.headers.update({'X-CSRFToken': csrf, 'Referer': BASE})

# Delete all dashboards
r = s.get(f'{BASE}/api/v1/dashboard/?q=' + json.dumps({'page_size': 100}))
for d in r.json()['result']:
    dr = s.delete(f'{BASE}/api/v1/dashboard/{d["id"]}')
    print(f'Deleted [{d["id"]}] {d["dashboard_title"]} -> {dr.status_code}')

def uid():
    return str(uuid.uuid4())[:8].upper()

def build_positions(rows):
    """
    rows: list of lists of (chart_id, width) — widths per row should sum to 24
    """
    pos = {
        'DASHBOARD_VERSION_KEY': 'v2',
        'ROOT_ID': {'type': 'ROOT', 'id': 'ROOT_ID', 'children': ['GRID_ID']},
        'GRID_ID': {'type': 'GRID', 'id': 'GRID_ID', 'children': [], 'parents': ['ROOT_ID']},
    }
    for row in rows:
        row_id = f'ROW-{uid()}'
        pos['GRID_ID']['children'].append(row_id)
        pos[row_id] = {
            'type': 'ROW', 'id': row_id, 'children': [],
            'parents': ['ROOT_ID', 'GRID_ID'],
            'meta': {'background': 'BACKGROUND_TRANSPARENT'},
        }
        for (cid, w) in row:
            key = f'CHART-{cid}-{uid()}'
            pos[row_id]['children'].append(key)
            pos[key] = {
                'type': 'CHART', 'id': key, 'children': [],
                'parents': ['ROOT_ID', 'GRID_ID', row_id],
                'meta': {'chartId': cid, 'width': w, 'height': 52},
            }
    return pos

def create_dashboard(title, rows):
    pos = build_positions(rows)
    r = s.post(f'{BASE}/api/v1/dashboard/', json={
        'dashboard_title': title,
        'published': True,
        'position_json': json.dumps(pos),
    })
    if r.status_code in (200, 201):
        did = r.json()['id']
        print(f'Created "{title}" -> http://localhost:8088/superset/dashboard/{did}/')
    else:
        print(f'Error {r.status_code}: {r.text[:300]}', file=sys.stderr)
        sys.exit(1)

# Chart IDs (created earlier):
#  1  Market Prices by Area (old)        13 Market Prices Over Time
#  2  Avg Price by Market Area (old)     14 Avg Price by Market Area
#  3  MTM Forward Curve (old)            15 Avg Volume by Market Area
#                                        16 MTM Forward Curve
#  17 Total Trades
#  18 Counterparties
#  19 Trades by Counterparty
#  20 Product Type Split
#  21 Physical vs Financial
#  22 Volume (MW) by Area
#  23 Credit Limits by Counterparty

print()
create_dashboard('Market Data — Prices & Curves', [
    [(13, 24)],           # full-width: price line over time
    [(14, 12), (15, 12)], # price bar | volume bar
    [(16, 24)],           # full-width: MTM forward curve
])

create_dashboard('Trade Book — Overview', [
    [(17, 6), (18, 6), (22, 12)],   # trade count | cpty count | volume bar
    [(19, 8), (20, 8), (21, 8)],    # 3 pies: by cpty, product type, phys/fin
    [(23, 24)],                      # full-width: credit limits
])

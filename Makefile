.PHONY: up down wipe nuke ps logs-mssql logs-kafka logs-clickhouse logs-mdm check-health s3-init clickhouse-init mssql-init mssql-run-init mdm-init mdm-shell init powerbi-views superset-up superset-logs superset-open kafka-create-counterparty-topic

# ── Start / stop ──────────────────────────────────────────────────
up:
	docker compose up -d

down:
	docker compose down

# WARNING: destroys all data volumes (keeps images cached)
wipe:
	docker compose down -v

# NUCLEAR: destroys volumes + removes all pulled images (full reset, slow next start)
nuke:
	docker compose down -v --rmi all

ps:
	docker compose ps

# ── Logs ──────────────────────────────────────────────────────────
logs-mssql:
	docker compose logs -f mssql

logs-kafka:
	docker compose logs -f kafka

logs-clickhouse:
	docker compose logs -f clickhouse

logs-grafana:
	docker compose logs -f grafana

logs-mdm:
	docker compose logs -f mdm-postgres

# ── Health check all containers ───────────────────────────────────
check-health:
	@echo "=== Container health ==="
	@docker compose ps
	@echo ""
	@echo "=== MSSQL ping (TCP check) ==="
	@docker exec etrm-mssql bash -c "cat /dev/null > /dev/tcp/localhost/1433 && echo 'Port 1433 open'" 2>/dev/null || echo "MSSQL not ready"
	@echo ""
	@echo "=== ClickHouse ping ==="
	@curl -s http://localhost:8123/ping
	@echo ""
	@echo "=== Kafka topics ==="
	@docker exec etrm-kafka kafka-topics --bootstrap-server localhost:9092 --list 2>/dev/null || echo "Kafka not ready yet"
	@echo ""
	@echo "=== MDM Postgres ==="
	@docker exec etrm-mdm-postgres pg_isready -U mdm -d mdm 2>/dev/null || echo "MDM Postgres not ready"
	@echo ""
	@echo "=== LocalStack S3 ==="
	@curl -s http://localhost:4566/_localstack/health | python3 -c "import sys,json; h=json.load(sys.stdin); print('s3:', h.get('services',{}).get('s3','?'))"

# ── Create S3 buckets in LocalStack ──────────────────────────────
# Run after 'make up' once LocalStack is healthy
s3-init:
	aws --endpoint-url=http://localhost:4566 s3 mb s3://etrm-payloads  --region ap-southeast-1 2>/dev/null || true
	aws --endpoint-url=http://localhost:4566 s3 mb s3://etrm-curves    --region ap-southeast-1 2>/dev/null || true
	aws --endpoint-url=http://localhost:4566 s3 mb s3://etrm-audit     --region ap-southeast-1 2>/dev/null || true
	@echo "S3 buckets ready:"
	@aws --endpoint-url=http://localhost:4566 s3 ls

# ── Seed / init (run once after 'make up') ───────────────────────

# Run ClickHouse DDL + seed data (safe to re-run: CREATE IF NOT EXISTS)
clickhouse-init:
	@echo "Running ClickHouse init..."
	@docker exec -i etrm-clickhouse clickhouse-client --multiquery < scripts/init_clickhouse.sql
	@echo "ClickHouse row counts:"
	@curl -s "http://localhost:8123/?query=SELECT+table,count()+FROM+etrm.market_data+GROUP+BY+table+UNION+ALL+SELECT+'mtm_curve',count()+FROM+etrm.mtm_curve"
	@curl -s "http://localhost:8123/?query=SELECT+'market_data',count()+FROM+etrm.market_data+UNION+ALL+SELECT+'mtm_curve',count()+FROM+etrm.mtm_curve"

# Run MSSQL DDL + seed data automatically via pymssql
# Falls back to connection info if pymssql isn't installed
mssql-run-init:
	@echo "=== Running MSSQL init via pymssql ==="
	@python3 -c "\
	import pymssql, sys;\
	conn = pymssql.connect(server='localhost', port=1433, user='sa', password='YourStr0ngPass1');\
	conn.autocommit(True);\
	cursor = conn.cursor();\
	sql = open('scripts/init_mssql.sql').read();\
	for batch in sql.split('\nGO\n'):\
	    batch = batch.strip();\
	    if batch and not batch.startswith('--'):\
	        try:\
	            cursor.execute(batch);\
	        except Exception as e:\
	            print(f'Batch warning: {e}', file=sys.stderr);\
	conn.close();\
	print('MSSQL init complete.');\
	" 2>&1 || (echo ""; echo "pymssql not installed. Install with: pip3 install pymssql"; echo "Or use DBeaver — see 'make mssql-init' for connection info")

# Print MSSQL connection info (for DBeaver / manual use)
mssql-init:
	@echo "=== MSSQL connection info ==="
	@echo "  Open DBeaver → New Connection → SQL Server"
	@echo "  Host: localhost  Port: 1433"
	@echo "  Auth: SQL Server  User: sa  Pass: YourStr0ngPass1"
	@echo "  Then run: scripts/init_mssql.sql"
	@echo ""
	@echo "  Or run 'make mssql-run-init' to seed automatically (requires: pip3 install pymssql)"

# Verify MDM Postgres golden_record seed data
mdm-init:
	@echo "=== MDM Postgres golden_record ==="
	@docker exec etrm-mdm-postgres psql -U mdm -d mdm -c "SELECT mdm_id, canonical_name, short_code, credit_limit, currency FROM golden_record;"

# Interactive MDM Postgres shell
mdm-shell:
	docker exec -it etrm-mdm-postgres psql -U mdm -d mdm

# Create counterparty.updated Kafka topic (if auto-create didn't work)
kafka-create-counterparty-topic:
	docker exec etrm-kafka kafka-topics --create --bootstrap-server localhost:9092 --topic counterparty.updated --partitions 3 --replication-factor 1 2>/dev/null || true

# Full init: clickhouse + mdm + mssql (auto-seeds all 3 databases)
init: clickhouse-init mdm-init mssql-run-init
	@echo ""
	@echo "Init complete. All 3 databases seeded. Run 'make check-health' to verify."

# ── Connect helpers ───────────────────────────────────────────────
clickhouse-shell:
	docker exec -it etrm-clickhouse clickhouse-client --database etrm

mssql-shell:
	@echo "Azure SQL Edge doesn't include sqlcmd. Use DBeaver or DataGrip:"
	@echo "  Host: localhost  Port: 1433  User: sa  Pass: YourStr0ngPass1  DB: etrm"

kafka-topics:
	docker exec etrm-kafka kafka-topics --bootstrap-server localhost:9092 --list

# ── Power BI reporting views ──────────────────────────────────────
# Run once after init to create flat views for Power BI to connect to.
# See docs/powerbi_setup.md for full guide.
powerbi-views:
	@echo "Creating ClickHouse Power BI views..."
	@docker exec -i etrm-clickhouse clickhouse-client --multiquery < scripts/powerbi_views_clickhouse.sql
	@echo "ClickHouse views done."
	@echo ""
	@echo "MSSQL Power BI views: connect via DBeaver and run scripts/powerbi_views_mssql.sql"
	@echo "  Host: localhost  Port: 1433  User: sa  DB: etrm"

# ── Superset (Power BI-style BI dashboards) ───────────────────────
# Start Superset alongside the rest of the stack.
# First boot takes ~2-3 min (pip installs + DB migration).
superset-up:
	docker compose up -d superset
	@echo "Superset starting at http://localhost:8088 (takes ~2-3 min on first boot)"
	@echo "Login: admin / admin"

superset-logs:
	docker compose logs -f superset

superset-open:
	open http://localhost:8088

# Publish a test trade event to Kafka
kafka-test-trade:
	echo '{"unique_id":"TEST-001","counterparty_mdm_id":"MDM-001","quantity":100,"price":11.5,"area_id":1}' | \
	docker exec -i etrm-kafka kafka-console-producer --bootstrap-server localhost:9092 --topic trade.events

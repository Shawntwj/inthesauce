#!/bin/bash
# Superset post-start init: registers MSSQL and ClickHouse as datasources.
# Runs in the background after superset starts (via docker-compose command).

set -e

SUPERSET_URL="http://localhost:8088"

echo "[superset-init] Waiting for Superset to be ready..."
until curl -sf "${SUPERSET_URL}/health" >/dev/null 2>&1; do
  sleep 5
done
echo "[superset-init] Superset is up. Registering databases..."

python3 -c "
import os
os.environ['FLASK_APP'] = 'superset'
from superset.app import create_app
app = create_app()
with app.app_context():
    from superset.extensions import db
    from superset.models.core import Database

    existing_names = [d.database_name for d in db.session.query(Database).all()]
    print('[superset-init] Existing DBs:', existing_names)

    if 'ETRM ClickHouse' not in existing_names:
        db.session.add(Database(
            database_name='ETRM ClickHouse',
            sqlalchemy_uri='clickhousedb://default@clickhouse:8123/etrm',
            expose_in_sqllab=True,
            allow_run_async=True,
        ))
        print('[superset-init] Registered ETRM ClickHouse')

    if 'ETRM MSSQL' not in existing_names:
        db.session.add(Database(
            database_name='ETRM MSSQL',
            sqlalchemy_uri='mssql+pymssql://sa:YourStr0ngPass1@mssql:1433/etrm',
            expose_in_sqllab=True,
            allow_run_async=True,
        ))
        print('[superset-init] Registered ETRM MSSQL')

    db.session.commit()
    print('[superset-init] Done. Open http://localhost:8088 — admin / admin')
"

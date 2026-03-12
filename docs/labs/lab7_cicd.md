# Lab 7 — GitHub Actions: CI/CD Pipelines

**Prereqs:** Labs 1-2 complete. GitHub repository set up. Basic Git knowledge.
**Time:** 45 minutes
**Goal:** Build a CI pipeline that lints, tests, and validates your sandbox on every push.

---

## Why This Matters

In production, code changes to the ETRM system go through a pipeline:
1. **Lint** — catch syntax errors and style issues
2. **Test** — run unit and integration tests
3. **Build** — compile Docker images
4. **Security scan** — check for vulnerabilities
5. **Deploy** — push to staging/production (via ArgoCD or similar)

You never deploy by running `docker compose up` on a production server. The pipeline enforces quality gates.

---

## Part A — Understand the Pipeline Structure (10 min)

### Task A1: Read through the workflow
We're going to create `.github/workflows/ci.yml`. Before writing it, understand the structure:

```
on: push/PR → triggers the workflow
jobs:
  lint:     → check SQL syntax, YAML validity
  validate: → terraform validate, docker compose config check
  test:     → spin up the stack, run queries, verify data
```

**Key concepts:**
- **Workflow** — a YAML file in `.github/workflows/` that defines automation
- **Job** — a unit of work that runs on a fresh VM (Ubuntu)
- **Step** — one command within a job
- **Artifact** — a file saved from a job for later use or debugging

### Task A2: Understand what we're testing
Since this is a data/infra project (not a Go service yet), our CI validates:
1. Docker Compose config is syntactically correct
2. Terraform config is valid
3. SQL scripts parse without errors
4. The full stack boots and seed data loads correctly

---

## Part B — Create the CI Pipeline (20 min)

### Task B1: Create the workflow file

```bash
mkdir -p .github/workflows
```

Create `.github/workflows/ci.yml` with this content:

```yaml
name: ETRM Sandbox CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  # ── Job 1: Validate configs ────────────────────────────────────
  validate:
    name: Validate Configs
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Validate Docker Compose
        run: docker compose config --quiet

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.7.0"

      - name: Terraform Init
        working-directory: infra/terraform
        run: terraform init -backend=false

      - name: Terraform Validate
        working-directory: infra/terraform
        run: terraform validate

      - name: Validate YAML files
        run: |
          echo "Checking Prometheus config..."
          python3 -c "import yaml; yaml.safe_load(open('infra/prometheus/prometheus.yml'))"
          echo "Checking Grafana datasources..."
          python3 -c "import yaml; yaml.safe_load(open('infra/grafana/provisioning/datasources/datasources.yml'))"
          echo "All YAML files valid."

  # ── Job 2: SQL syntax check ────────────────────────────────────
  sql-check:
    name: SQL Syntax Check
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Check MSSQL scripts exist and are non-empty
        run: |
          for f in scripts/init_mssql.sql scripts/powerbi_views_mssql.sql; do
            if [ ! -s "$f" ]; then
              echo "ERROR: $f is missing or empty"
              exit 1
            fi
            echo "OK: $f ($(wc -l < "$f") lines)"
          done

      - name: Check ClickHouse scripts exist and are non-empty
        run: |
          for f in scripts/init_clickhouse.sql scripts/powerbi_views_clickhouse.sql; do
            if [ ! -s "$f" ]; then
              echo "ERROR: $f is missing or empty"
              exit 1
            fi
            echo "OK: $f ($(wc -l < "$f") lines)"
          done

      - name: Check for common SQL mistakes
        run: |
          echo "Checking for UPDATE/DELETE on ClickHouse scripts (should not exist)..."
          if grep -n "^UPDATE\|^DELETE" scripts/init_clickhouse.sql scripts/powerbi_views_clickhouse.sql; then
            echo "ERROR: Found UPDATE/DELETE in ClickHouse scripts — ClickHouse is append-only!"
            exit 1
          fi
          echo "No prohibited statements found."

  # ── Job 3: Integration test (full stack boot) ──────────────────
  integration:
    name: Stack Boot Test
    runs-on: ubuntu-latest
    needs: [validate, sql-check]
    steps:
      - uses: actions/checkout@v4

      - name: Start core services
        run: docker compose up -d mssql clickhouse
        env:
          MSSQL_SA_PASSWORD: YourStr0ngPass1

      - name: Wait for ClickHouse
        run: |
          echo "Waiting for ClickHouse..."
          for i in $(seq 1 30); do
            if curl -sf http://localhost:8123/ping > /dev/null 2>&1; then
              echo "ClickHouse is ready."
              break
            fi
            echo "Attempt $i/30..."
            sleep 5
          done

      - name: Wait for MSSQL
        run: |
          echo "Waiting for MSSQL..."
          for i in $(seq 1 30); do
            if docker exec etrm-mssql bash -c "cat /dev/null > /dev/tcp/localhost/1433" 2>/dev/null; then
              echo "MSSQL is ready."
              break
            fi
            echo "Attempt $i/30..."
            sleep 5
          done

      - name: Run ClickHouse init
        run: docker exec -i etrm-clickhouse clickhouse-client --multiquery < scripts/init_clickhouse.sql

      - name: Verify ClickHouse data
        run: |
          echo "Market data rows:"
          curl -s "http://localhost:8123/?query=SELECT+count()+FROM+etrm.market_data"
          echo ""
          echo "Transaction exploded rows:"
          curl -s "http://localhost:8123/?query=SELECT+count()+FROM+etrm.transaction_exploded"
          echo ""
          echo "MTM curve rows:"
          curl -s "http://localhost:8123/?query=SELECT+count()+FROM+etrm.mtm_curve"

          # Verify we have data
          MD_COUNT=$(curl -s "http://localhost:8123/?query=SELECT+count()+FROM+etrm.market_data")
          if [ "$MD_COUNT" -lt 4000 ]; then
            echo "ERROR: Expected 4000+ market_data rows, got $MD_COUNT"
            exit 1
          fi

      - name: Stop services
        if: always()
        run: docker compose down -v
```

### Task B2: Commit and push
```bash
git add .github/workflows/ci.yml
git commit -m "Add CI pipeline: validate, SQL check, integration test"
git push
```

### Task B3: Watch it run
1. Go to your GitHub repository in a browser
2. Click the **Actions** tab
3. Watch the workflow run — click into each job to see the logs

**Expected:** All 3 jobs pass (green checkmarks).

---

## Part C — Understand the Pipeline (10 min)

### Task C1: Read the logs
Click into each job in the GitHub Actions UI and read the output of each step. Note:

- **validate job:** How long did `terraform init` take? What did `terraform validate` check?
- **sql-check job:** What SQL anti-patterns did it check for?
- **integration job:** How long did it take for MSSQL and ClickHouse to start? How many rows were seeded?

### Task C2: Break the pipeline on purpose
Make a deliberate error and see the pipeline catch it.

Option A — Break Terraform:
```bash
# Add invalid syntax to main.tf
echo "INVALID SYNTAX HERE" >> infra/terraform/main.tf
git add -A && git commit -m "test: break terraform" && git push
```

Watch the `validate` job fail with a Terraform syntax error. Then fix it:
```bash
# Remove the bad line, commit, push
git checkout -- infra/terraform/main.tf
git add -A && git commit -m "fix: restore terraform config" && git push
```

Option B — Add a ClickHouse anti-pattern:
```bash
# Add an UPDATE statement to a ClickHouse script
echo "UPDATE etrm.market_data SET price = 0 WHERE area_id = 1;" >> scripts/init_clickhouse.sql
git add -A && git commit -m "test: break sql check" && git push
```

Watch the `sql-check` job fail. Then fix it.

### Task C3: Understand job dependencies
Look at `needs: [validate, sql-check]` on the integration job. This means:
- `validate` and `sql-check` run in parallel (faster)
- `integration` only runs if both pass (no point booting the stack if configs are invalid)

**Question:** Why not run all 3 jobs in parallel? (Answer: The integration test is expensive — it boots Docker containers and takes minutes. Running it only after cheaper checks pass saves CI minutes.)

---

## Part D — Extend the Pipeline (5 min)

Think about what you'd add next:

| Stage | What It Does | When to Add |
|-------|-------------|-------------|
| **Docker build** | Build Go service image, push to ECR | When Go service exists |
| **Security scan** | Trivy scan on Docker images | Before deploying anywhere |
| **Deploy to staging** | ArgoCD sync / Terraform apply to real AWS | When real AWS is configured |
| **Smoke test** | Hit API endpoints after deploy, verify responses | After deploy step |
| **Notification** | Slack/Teams message on failure | Immediately (use `slackapi/slack-github-action`) |

---

## Checkpoint: What You Should Be Able to Do

- [ ] Explain what CI/CD means and why trading firms use pipelines
- [ ] Create a GitHub Actions workflow with multiple jobs
- [ ] Understand `on:`, `jobs:`, `steps:`, `needs:`, and `if:` in workflow YAML
- [ ] Make a pipeline fail deliberately and fix it
- [ ] Explain why jobs have dependencies (cheap checks first, expensive tests last)
- [ ] Describe what additional stages a production pipeline would have

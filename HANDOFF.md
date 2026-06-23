# ars_intel — Handoff State (2026-06-23)

## Status
- **Scaffold + 9 rules + scorer + frontend + worker** — complete
- **AUDIT.md blockers (11)** — fixed
- **Local git commit** — `a612430` on `main`
- **Push to GitHub** — **PENDING** (gh CLI keyring token expired; needs interactive auth)
- **Snowflake DDL execution** — pending (needs `SNOWFLAKE_PASSWORD`)
- **Initial replication** — pending
- **CF deploy** — pending

## Resume in 4 steps (~30 min)

### 1. Push to GitHub
```bash
gh auth login -h github.com -p https
cd C:/Users/akash.agarwal/projects/ars_intel
gh repo create akash0631/ars_intel --public --source=. --push
```

### 2. Snowflake bootstrap
```bash
# Inject password
export SNOWFLAKE_PASSWORD='<your-password>'
export SQL_PASSWORD='Vrl@12345'

# Run DDL via SnowSQL or Snowsight Web UI in order:
#   sql/ddl/01_schemas.sql
#   sql/ddl/02_bronze_tables.sql
#   sql/ddl/03_silver_views.sql
#   sql/ddl/04_mart_alerts.sql
```

### 3. First replication (full load, ~30 min for 22M+11M rows)
```bash
cd replication
pip install -r requirements.txt
python ars_replicate.py --full
```

### 4. Rules + Marts + CF deploy
```bash
# Rules (idempotent)
for f in sql/rules/R*.sql; do snowsql -f $f; done

# Marts
for f in sql/marts/*.sql; do snowsql -f $f; done

# Worker (after generating RSA keypair + ALTER USER ... SET RSA_PUBLIC_KEY)
cd worker
npm install
wrangler secret put SNOWFLAKE_PRIVATE_KEY  # paste PEM
wrangler deploy

# Frontend
cd ../web
npm install
npm run build
wrangler pages deploy out/ --project-name=ars-intel
```

### 5. Cron incremental on V2DC-ADDVERB (.36)
See `replication/cron.md` — Task Scheduler every 30 min.

## What got fixed post-scaffold audit

| File | Issue | Fix |
|---|---|---|
| sql/ddl/03_silver_views.sql | Missing per-attr `*_REQ`/`*_CONT` cols on V_SILVER_LISTING | Added all 8 attr rollups |
| sql/ddl/03_silver_views.sql | No V_SILVER_SESSION_MAJCAT for R9 | Added view joining ARS_ALLOC_MAJCAT_QUEUE on time window |
| sql/ddl/03_silver_views.sql | No V_SILVER_PEND_ALC for R8 | Added raw passthrough view |
| sql/ddl/03_silver_views.sql | V_SILVER_ALLOC missing RUN_DATE | Joined ARS_LISTING_SESSIONS |
| sql/ddl/03_silver_views.sql | V_SILVER_SESSIONS missing FINISHED_AT (worker expects) | Added NULL placeholder column |
| sql/rules/R3_ATTR_MIX_DRIFT.sql | `V2RETAIL.ARS_GOLD.MASTER_PRODUCT` (wrong schema) | → `V2RETAIL.ARS_BRONZE.MASTER_PRODUCT` (2 places) |
| sql/rules/R8_BDC_PIPELINE_DEAD.sql | Read `V_SILVER_REQUIREMENT` cols that don't exist | → `V_SILVER_PEND_ALC` |
| sql/rules/R9_MAJCAT_REGRESSION.sql | Read MAJCAT cols from `V_SILVER_SESSIONS` | → `V_SILVER_SESSION_MAJCAT` |
| sql/marts/MART_ALERTS_TOP.sql | `s.WERKS` join (col is `STORE` in MART_ALERTS) | → `s.STORE` |
| sql/marts/MART_DAILY_ROLLUP.sql | Pivot on `RULE_CODE` enum `ZERO_ALLOC/...` (dead) | → Pivot on `RULE_ID` = R1..R10 |
| sql/marts/MART_DRILL_SESSION.sql | `WERKS`/`RULE_CODE` references | → `STORE`/`RULE_ID` (listing_ctx aliases WERKS→STORE) |
| worker/src/index.ts | ORDER BY `ALERT_SCORE` (no such col) | → `SEVERITY` |

## Known deferred items
- R2 LOW: redundant MAJ_CAT join in MASTER_PRODUCT — cosmetic
- replication LOW: watermark advance before stream completes — benign at 100k chunks
- R6 SCORE_LOSS not built — needs ARS code patch to populate SCORE in ALLOC_HISTORY

## Files
- 9 rule SQLs in `sql/rules/`
- 4 DDL SQLs in `sql/ddl/`
- 3 mart SQLs in `sql/marts/`
- 1 Python replication script in `replication/`
- 1 CF Worker (Hono + Snowflake REST) in `worker/`
- 1 Next.js dashboard (3 pages + 3 components) in `web/`

## See also
- `AUDIT.md` — full audit findings (pre-fix snapshot)
- `DEPLOY.md` — step-by-step runbook
- `SQL_RUN_ORDER.md` — exact SQL execution order
- `Makefile` — `make all` automation

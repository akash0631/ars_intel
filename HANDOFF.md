# ars_intel — LIVE State (2026-06-24)

## URLs
- **Dashboard:** https://ars-intel.pages.dev (CF Pages)
- **API:** https://ars-intel-api.akash-bab.workers.dev (CF Worker, Snowflake REST proxy via KEYPAIR_JWT)
- **Repo:** https://github.com/akash0631/ars_intel

## Snowflake State (V2RETAIL.ARS_BRONZE + ARS_GOLD)

| Table | Rows | Note |
|---|---|---|
| ARS_LISTING_SESSIONS | 62 | full |
| ARS_LISTING_HISTORY | 15.3M | full |
| ARS_ALLOC_HISTORY | ~11.6M | full |
| ARS_ALLOC_MAJCAT_QUEUE | 4,189 | full |
| ARS_PEND_ALC | ~1.1M | full |
| ARS_PEND_ALC_OPERATIONS | ~30 | full |
| ARS_MSA_VAR_ART | 199,736 | full |
| MASTER_CONT_RNG_SEG | 1.03M | full |
| MASTER_CONT_FAB | 1,620 | full |
| MASTER_CONT_CLR | 5,522 | full |
| MASTER_CONT_FIT | 195,850 | full |
| MASTER_CONT_M_VND_CD | 2,758 | full |
| MASTER_CONT_M_YARN_02 | 1.05M | full |
| MASTER_CONT_WEAVE_2 | 819,401 | full |
| MASTER_CONT_MERGE_RNG_SEG | 515,088 | full |
| STORE_PLANT_MASTER | 491 | full |
| MASTER_PRODUCT | 3.58M | full |
| MASTER_CONT_SZ | 0 | empty stub (source 0 rows) |
| MASTER_ALC_INPUT_ST_ART | 0 | empty stub (source 0 rows) |
| ET_SALES_DATA | ~3.8M | partial (SSL crash mid-stream) |

## MART_ALERTS State

| Rule | Status | Alerts | Note |
|---|---|---|---|
| R1 MSA_UNALLOC | ✓ | **1,235,407** | bulk dominant |
| R2 SIZE_MIX_DRIFT | ✗ | 0 | TRY_CAST NUMBER↔VARCHAR error — fix needed |
| R3 ATTR_MIX_DRIFT | ✗ | 0 | col error line 45 — fix needed |
| R4 CAP_BIND | ✗ | 0 | syntax error — fix needed |
| R5 DC_OOS_GAP | ✗ | 0 | col error line 37 — fix needed |
| R7 HOLD_HEAVY | ✓ | 15 | |
| R8 BDC_PIPELINE_DEAD | ✓ | 0 | (none stuck currently) |
| R9 MAJCAT_REGRESSION | ✓ | 274 | |
| R10 STORE_STARVATION | ✓ | 1 | |

**Total MART_ALERTS:** ~1.24M

## Worker endpoints (smoke-verified)
- `GET /api/health` → 200 `{ok:true}`
- `GET /api/alerts/top?limit=N` → 200 JSON rows
- `GET /api/alerts/trends?days=30` → 200
- `GET /api/drill/sessions?run_date=YYYY-MM-DD` → 200
- `GET /api/drill/store-majcat?session_id=&maj_cat=&store=` → 200

## Auth chain
- **Snowflake user:** akashv2kart
- **Auth:** KEYPAIR_JWT
- **Private key:** `~/.snowflake/akashv2kart_rsa.p8` (PKCS#8, registered Apr 18 2026)
- **Public key fingerprint:** `SHA256:bAMWF54WXvnvwYbjUZzPmwckrQqtKSzWG4WkFk6PDeQ=`
- **Worker secrets:** `SNOWFLAKE_PRIVATE_KEY`, `SNOWFLAKE_PRIVATE_KEY_FP`

## Cron
Task Scheduler `ars_intel_replicate_inc` — every 30 min, runs `replication/run_incremental.bat`.
First fire: T+40 min after registration.
Log: `.secrets/replicate_inc.log`

## Known gaps
1. **4 rules failing** (R2/R3/R4/R5) — rule SQL was written against assumed schema; bronze schema differs. Each rule needs col-mapping fix (~1h each).
2. **ET_SALES_DATA partial** — SSL connection broke at 3.8M rows. R2 needs full sale data. Re-run `python replication/ars_replicate.py --incremental` will catch up.
3. **MASTER_ALC_INPUT_ST_ART empty in source** — V_SILVER_REQUIREMENT is a NULL view. Affects no rules currently.
4. **MASTER_CONT_SZ empty in source** — R2 needs CONT_SZ baseline.

## Resume from blank machine
```bash
# 1. Clone
gh repo clone akash0631/ars_intel && cd ars_intel

# 2. Snowflake bootstrap (DDL idempotent, safe to re-run)
export SNOWFLAKE_PASSWORD='<rotate-or-use-keypair>'
python replication/run_sql.py sql/ddl/01_schemas.sql sql/ddl/02_bronze_tables.sql sql/ddl/03_silver_views.sql sql/ddl/04_mart_alerts.sql

# 3. Incremental replication (catches deltas only)
export SQL_PASSWORD='Vrl@12345'
python replication/ars_replicate.py --incremental

# 4. Re-run rules + marts (idempotent — each rule DELETEs+INSERTs its scope)
python replication/run_sql.py sql/marts/MART_ALERTS_TOP.sql sql/marts/MART_DAILY_ROLLUP.sql sql/marts/MART_DRILL_SESSION.sql
RUN_SQL_CONTINUE_ON_ERROR=1 python replication/run_sql.py sql/rules/R*.sql

# 5. CF deploy refresh
cd worker && wrangler deploy
cd ../web && npx next build && wrangler pages deploy out --project-name ars-intel
```

## Architecture
```
arsdbpro/Rep_Data (SQL Server) 
   ↓  pymssql (every 30min Task Scheduler)
V2RETAIL.ARS_BRONZE (Snowflake, 19 tables auto-created via write_pandas)
   ↓  silver views (V_SILVER_SESSIONS, V_SILVER_LISTING, V_SILVER_ALLOC, V_SILVER_PEND_ALC, V_SILVER_DC_STOCK, V_SILVER_SESSION_MAJCAT)
ARS_GOLD silver layer
   ↓  9 rule detector SQLs (R1-R10 minus R6)
ARS_GOLD.MART_ALERTS (severity-ranked)
   ↓  3 mart views (MART_ALERTS_TOP / MART_DAILY_ROLLUP / MART_DRILL_SESSION)
ARS_GOLD mart layer
   ↓  CF Worker proxies Snowflake REST API (KEYPAIR_JWT auth)
https://ars-intel-api.akash-bab.workers.dev
   ↓  Next.js 14 static export on CF Pages
https://ars-intel.pages.dev (Today / Trends / Drill tabs)
```

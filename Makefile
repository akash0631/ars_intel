# ars_intel — assembly Makefile.
# Targets are sequential pieces of DEPLOY.md so a clean machine can ship with
# `make all`. Requires snowsql, python, npm, wrangler on PATH plus a populated
# replication/.env file (SQL_PASSWORD + SNOWFLAKE_PASSWORD).

SNOWSQL  ?= snowsql
PY        = replication/.venv/Scripts/python.exe
SF_FLAGS  = -a iafphkw-hh80816 -u akashv2kart -w ALLOC_WH -d V2RETAIL

# Auto-detect: on Linux/Mac the venv lives under bin/, on Windows under Scripts/
ifeq ($(OS),Windows_NT)
  PY = replication/.venv/Scripts/python.exe
else
  PY = replication/.venv/bin/python
endif

.PHONY: help all schemas replicate-full replicate-inc rules marts refresh \
        worker-deploy web-build web-deploy venv clean

help:
	@echo "ars_intel make targets:"
	@echo "  venv             create replication/.venv and install deps"
	@echo "  schemas          create ARS_BRONZE + ARS_GOLD + tables + views"
	@echo "  replicate-full   TRUNCATE+INSERT all bronze tables from SQL Server"
	@echo "  replicate-inc    watermark-based incremental refresh"
	@echo "  rules            run R1..R10 rule SQLs (no R6) -> MART_ALERTS"
	@echo "  marts            (re)build MART_ALERTS_TOP/MART_DAILY_ROLLUP/MART_DRILL_SESSION"
	@echo "  refresh          rules + marts (cron target after replicate-inc)"
	@echo "  worker-deploy    deploy Cloudflare Worker (ars-intel-api)"
	@echo "  web-build        next build (static export)"
	@echo "  web-deploy       wrangler pages deploy out/"
	@echo "  all              one-shot bootstrap: schemas + replicate-full + refresh + worker + web"

# ----- bootstrap a clean machine -------------------------------------------
all: venv schemas replicate-full refresh worker-deploy web-deploy

# ----- python venv ----------------------------------------------------------
venv:
	cd replication && python -m venv .venv
	$(PY) -m pip install --upgrade pip
	$(PY) -m pip install -r replication/requirements.txt

# ----- snowflake ------------------------------------------------------------
schemas:
	$(SNOWSQL) $(SF_FLAGS) -f sql/ddl/01_schemas.sql
	$(SNOWSQL) $(SF_FLAGS) -f sql/ddl/02_bronze_tables.sql
	$(SNOWSQL) $(SF_FLAGS) -f sql/ddl/03_silver_views.sql
	$(SNOWSQL) $(SF_FLAGS) -f sql/ddl/04_mart_alerts.sql

rules:
	$(SNOWSQL) $(SF_FLAGS) -f sql/rules/R1_MSA_UNALLOC.sql
	$(SNOWSQL) $(SF_FLAGS) -f sql/rules/R2_SIZE_MIX_DRIFT.sql
	$(SNOWSQL) $(SF_FLAGS) -f sql/rules/R3_ATTR_MIX_DRIFT.sql
	$(SNOWSQL) $(SF_FLAGS) -f sql/rules/R4_CAP_BIND.sql
	$(SNOWSQL) $(SF_FLAGS) -f sql/rules/R5_DC_OOS_GAP.sql
	$(SNOWSQL) $(SF_FLAGS) -f sql/rules/R7_HOLD_HEAVY.sql
	$(SNOWSQL) $(SF_FLAGS) -f sql/rules/R8_BDC_PIPELINE_DEAD.sql
	$(SNOWSQL) $(SF_FLAGS) -f sql/rules/R9_MAJCAT_REGRESSION.sql
	$(SNOWSQL) $(SF_FLAGS) -f sql/rules/R10_STORE_STARVATION.sql

marts:
	$(SNOWSQL) $(SF_FLAGS) -f sql/marts/MART_ALERTS_TOP.sql
	$(SNOWSQL) $(SF_FLAGS) -f sql/marts/MART_DAILY_ROLLUP.sql
	$(SNOWSQL) $(SF_FLAGS) -f sql/marts/MART_DRILL_SESSION.sql

refresh: rules marts

# ----- replication ----------------------------------------------------------
replicate-full:
	$(PY) replication/ars_replicate.py --full

replicate-inc:
	$(PY) replication/ars_replicate.py --incremental

# ----- worker ---------------------------------------------------------------
worker-deploy:
	cd worker && npm install && npm run deploy

# ----- web ------------------------------------------------------------------
web-build:
	cd web && npm install && npm run build

web-deploy: web-build
	cd web && wrangler pages deploy out/ --project-name ars-intel-web --branch main

clean:
	rm -rf web/.next web/out worker/node_modules web/node_modules replication/.venv

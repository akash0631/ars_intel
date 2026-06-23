# Changelog

All notable changes to `ars_intel` will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project follows [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [0.1.0] — 2026-06-23

Initial scaffold of the ars_intel rules-driven allocation gap detector.

### Added

- **Replication** (`replication/ars_replicate.py`) — Python loader mirroring
  19 tables from `arsdbpro/Rep_Data` (SQL Server, HOPC345) into
  `V2RETAIL.ARS_BRONZE`. Full + watermark-incremental modes; watermarks
  tracked in `V2RETAIL.ARS_GOLD.REPLICATION_WATERMARKS`.
- **DDL** (`sql/ddl/01..04`) — schemas, bronze tables, silver views
  (`V_SILVER_SESSIONS / LISTING / ALLOC / REQUIREMENT / DC_STOCK`),
  `MART_ALERTS` table.
- **Rules** (`sql/rules/R1..R10`, skipping R6) — 9 idempotent detectors
  emitting into `MART_ALERTS` with explicit
  `LOST_QTY * STORE_PRIORITY * MAJCAT_PRIORITY * RECENCY_DECAY * RULE_WEIGHT`
  severity formula.
- **Marts** (`sql/marts/MART_ALERTS_TOP, MART_DAILY_ROLLUP, MART_DRILL_SESSION`)
  — consumption views used by the UI.
- **Worker** (`worker/`) — Cloudflare Worker `ars-intel-api` proxying read-only
  Snowflake queries with key-pair JWT auth and named-bind parameters. Endpoints
  `/api/health`, `/api/alerts/top`, `/api/alerts/trends`,
  `/api/drill/sessions`, `/api/drill/store-majcat`.
- **Web** (`web/`) — Next.js 14 static export with Today / Trends / Drill
  pages, deployed to Cloudflare Pages with `_redirects` proxying `/api/*` to
  the worker.
- **Runbooks** — `DEPLOY.md` (8-step ship), `SQL_RUN_ORDER.md` (file order),
  `Makefile` (`make all` bootstrap), `AUDIT.md` (initial code audit).

### Known issues (tracked in AUDIT.md)

- Column-name mismatch between `MART_ALERTS` (uses `RULE_ID`, `STORE`) and the
  mart views (`MART_DAILY_ROLLUP`, `MART_DRILL_SESSION`, `MART_ALERTS_TOP`
  reference `RULE_CODE` / `WERKS`).
- `V_SILVER_REQUIREMENT` is a pre-aggregated view of `MASTER_ALC_INPUT_ST_ART`,
  but `R8_BDC_PIPELINE_DEAD.sql` reads raw `ARS_PEND_ALC` columns from it
  (`APPROVED_AT`, `BDC_QTY`, `IS_CLOSED`, ...). Rule will fail at compile.
- `R9_MAJCAT_REGRESSION.sql` references `MAJCAT_STATUS`, `MAJCAT_ERROR_MSG`,
  `MAJCAT_SHIP_QTY` etc. on `V_SILVER_SESSIONS` — none of those exist in the
  silver view. Needs join into `ARS_ALLOC_MAJCAT_QUEUE`.
- Worker `/api/alerts/top` selects `ALERT_SCORE` and `/api/drill/sessions`
  selects `FINISHED_AT`; neither column exists in the corresponding source.
- See `AUDIT.md` for the full list and exact line references.

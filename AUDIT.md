# AUDIT — ars_intel v0.1.0

Static audit of every file in the repo at scaffold time. Goal: flag schema
mismatches, dead references, and any SQL-Server-flavored syntax that snuck
into a Snowflake target. **No source files were modified by this audit.**

Scope of checks per file:

1. Every column reference resolves to a column that exists in
   `sql/ddl/02_bronze_tables.sql` or `sql/ddl/03_silver_views.sql`.
2. Every fully-qualified table/view exists in the schema named.
3. No SQL Server idiom (`GETDATE()`, `WITH(NOLOCK)`, `TOP n`, `ISNULL`,
   `+` for string concat, `DATEDIFF(day,a,b)` without quoted unit, etc.).
4. Idempotency clauses (`DELETE … WHERE RULE_ID = …`) match the spec.

Severity legend:

- **BLOCKER** — file will fail at parse/compile/execute time.
- **HIGH**    — file runs but emits wrong data.
- **LOW**     — cosmetic / inefficiency.

---

## Summary

| File                                          | Status   | Issues  |
| --------------------------------------------- | -------- | ------- |
| sql/ddl/01_schemas.sql                        | clean    | 0       |
| sql/ddl/02_bronze_tables.sql                  | clean    | 0       |
| sql/ddl/03_silver_views.sql                   | clean    | 0       |
| sql/ddl/04_mart_alerts.sql                    | clean    | 0       |
| sql/rules/R1_MSA_UNALLOC.sql                  | clean    | 0       |
| sql/rules/R2_SIZE_MIX_DRIFT.sql               | LOW      | 1       |
| sql/rules/R3_ATTR_MIX_DRIFT.sql               | BLOCKER  | 3       |
| sql/rules/R4_CAP_BIND.sql                     | BLOCKER  | 1       |
| sql/rules/R5_DC_OOS_GAP.sql                   | clean    | 0       |
| sql/rules/R7_HOLD_HEAVY.sql                   | clean    | 0       |
| sql/rules/R8_BDC_PIPELINE_DEAD.sql            | BLOCKER  | 1       |
| sql/rules/R9_MAJCAT_REGRESSION.sql            | BLOCKER  | 2       |
| sql/rules/R10_STORE_STARVATION.sql            | clean    | 0       |
| sql/marts/MART_ALERTS_TOP.sql                 | BLOCKER  | 1       |
| sql/marts/MART_DAILY_ROLLUP.sql               | BLOCKER  | 2       |
| sql/marts/MART_DRILL_SESSION.sql              | BLOCKER  | 2       |
| worker/src/index.ts                           | HIGH     | 2       |
| replication/ars_replicate.py                  | LOW      | 1       |

No `GETDATE()` / `WITH(NOLOCK)` / SQL-Server-only syntax was found anywhere
in the rule SQLs or mart SQLs. All dialect issues below are Snowflake-on-
Snowflake column/object mismatches.

---

## Findings — DDL layer (clean)

`01..04` create exactly what they advertise. `MART_ALERTS` schema:

```
RULE_ID, SESSION_ID, RUN_DATE, STORE, MAJ_CAT, GEN_ART_NUMBER,
VAR_ART, ATTR_DIM, ATTR_VAL, LOST_QTY, ROOT_CAUSE, FIX_ACTION,
SEVERITY, DETAIL_JSON, CREATED_AT, ALERT_ID (autoinc PK)
```

Key naming choices that the downstream layer must respect:

- Column name is **`RULE_ID`**, not `RULE_CODE`.
- Column name is **`STORE`**, not `WERKS`.
- No `ALERT_SCORE` column — severity is in `SEVERITY`.

The rule SQLs (R1, R2, R4, R5, R7, R8, R9, R10) all `INSERT` into the
correct `RULE_ID` / `STORE` columns. The mart layer and worker do not.

---

## Findings — Rule SQLs

### R2_SIZE_MIX_DRIFT.sql — LOW (1)

- **L280-281**: `mp.MAJ_CAT` join via `V2RETAIL.ARS_BRONZE.MASTER_PRODUCT`
  is redundant — `V_SILVER_ALLOC` already exposes `MAJ_CAT` via the same
  master join. Cosmetic, no correctness impact.

### R3_ATTR_MIX_DRIFT.sql — BLOCKER (3)

- **L67-68 / L98-99** (`majcat_ship_30d` and `alloc_attr` CTEs):
  `JOIN V2RETAIL.ARS_GOLD.MASTER_PRODUCT mp` — table lives in
  `ARS_BRONZE`, not `ARS_GOLD`. Will fail with
  `SQL compilation error: Object 'V2RETAIL.ARS_GOLD.MASTER_PRODUCT' does
  not exist`. Should be `V2RETAIL.ARS_BRONZE.MASTER_PRODUCT`.
- **L111-145 (`baseline` CTE)**: references columns
  `FAB_CONT`, `CLR_CONT`, `RNG_SEG_CONT`, `FIT_CONT`, `M_VND_CD_CONT`,
  `M_YARN_02_CONT`, `WEAVE_2_CONT` on `V_SILVER_LISTING`. The silver
  view (`sql/ddl/03_silver_views.sql`) only re-exposes the `MJ_*` rollups
  (`MJ_STK_TTL, MJ_STR, MJ_CONT, MJ_MBQ, MJ_OPT_CNT, MJ_DISP_Q, MJ_REQ,
  MJ_REQ_WITH_EXC, MJ_REQ_NO_EXC`) plus per-option columns. The
  per-attribute `*_CONT` rollup columns from `ARS_LISTING_HISTORY` are
  **not projected** by the silver view. Either extend the view or change
  R3 to read those columns directly from `ARS_BRONZE.ARS_LISTING_HISTORY`.

### R4_CAP_BIND.sql — BLOCKER (1)

- **L94-110 (the `cap` CROSS JOIN LATERAL)**: same root cause as R3. R4
  reads `l.MERGE_RNG_SEG_REQ / l.MERGE_RNG_SEG_CONT`,
  `l.RNG_SEG_REQ / l.RNG_SEG_CONT`, `l.M_YARN_02_REQ / _CONT`,
  `l.WEAVE_2_REQ / _CONT`, `l.FAB_REQ / _CONT`, `l.CLR_REQ / _CONT`,
  `l.M_VND_CD_REQ / _CONT`, `l.FIT_REQ / _CONT` from `V_SILVER_LISTING`.
  None of these columns are exposed by the silver view DDL — only the
  bronze `ARS_LISTING_HISTORY` table has them. R4 will fail with
  `invalid identifier 'L.MERGE_RNG_SEG_REQ'`.

### R8_BDC_PIPELINE_DEAD.sql — BLOCKER (1)

- **L56-67 (`stuck_rows` CTE)**: reads `p.ST_CD, p.MAJ_CAT,
  p.GEN_ART_NUMBER, p.ARTICLE_NUMBER, p.QTY, p.APPROVED_AT, p.LAST_BDC_AT,
  p.IS_CLOSED, p.BDC_QTY` from `V_SILVER_REQUIREMENT`.
  `V_SILVER_REQUIREMENT` is a `GROUP BY ST_CD, MAJ_CAT` rollup of
  `MASTER_ALC_INPUT_ST_ART` (sql/ddl/03_silver_views.sql L129-144) and
  exposes only `WERKS, MAJ_CAT, GEN_ART_COUNT, LISTING_CNT, I_ROD_CNT,
  FOCUS_W_CAP_CNT, FOCUS_WO_CAP_CNT, CORE_CNT, AUTO_CNT, HH_ART_CNT,
  AVG_MANUAL_DENSITY, LAST_UPLOAD_AT`. The columns R8 wants belong to
  `ARS_BRONZE.ARS_PEND_ALC`. Either point the rule at
  `V2RETAIL.ARS_BRONZE.ARS_PEND_ALC` directly or add a new silver view
  (`V_SILVER_PEND_ALC`) that exposes those raw columns.

### R9_MAJCAT_REGRESSION.sql — BLOCKER (2)

- **L52-60 (`sess` CTE)**: selects `s.MAJ_CAT, s.MAJCAT_STATUS,
  s.MAJCAT_ERROR_MSG, s.MAJCAT_SHIP_QTY, s.MAJCAT_HOLD_QTY,
  s.MAJCAT_ROWS_AFFECTED, s.MAJCAT_ATTEMPTS, s.MAJCAT_DURATION_SEC` from
  `V_SILVER_SESSIONS`. The silver view (sql/ddl/03_silver_views.sql L9-23)
  is a pure projection of `ARS_LISTING_SESSIONS` and does not expose any
  `MAJCAT_*` per-row columns — those live in
  `ARS_BRONZE.ARS_ALLOC_MAJCAT_QUEUE`. Fix: extend the silver view to
  `JOIN ARS_ALLOC_MAJCAT_QUEUE` on `SESSION_ID` (one row per
  session × maj_cat) OR have R9 read the queue table directly.
- **L114, L138 (`majcat_30d`, `cur_alloc_rollup` CTEs)**: reference
  `a.RUN_DATE` on `V_SILVER_ALLOC`. The silver view does not expose
  `RUN_DATE` — it must be obtained via `JOIN V_SILVER_SESSIONS s ON
  s.SESSION_ID = a.SESSION_ID`. R9 will fail with
  `invalid identifier 'A.RUN_DATE'`.

---

## Findings — Mart SQLs

### MART_ALERTS_TOP.sql — BLOCKER (1)

- **L38**: `LEFT JOIN STORE_PLANT_MASTER spm ON spm.PLANT_CODE = s.WERKS`.
  `MART_ALERTS` defines the column as `STORE`, not `WERKS`. The join
  will fail with `invalid identifier 'S.WERKS'`. (Same issue surfaces
  again in the worker's API contract — see below.)

### MART_DAILY_ROLLUP.sql — BLOCKER (2)

- **L22-29 (`per_rule` CTE)**: groups by `RULE_CODE` and joins on
  `COUNT(DISTINCT WERKS)`. `MART_ALERTS` has neither column — they are
  named `RULE_ID` and `STORE`. Fails with `invalid identifier`.
- **L36-91**: every pivoted `CASE WHEN RULE_CODE = 'ZERO_ALLOC' …`
  branch is dead. The rule layer emits `RULE_ID` values
  `R1, R2, R3, R4, R5, R7, R8, R9, R10`, never the legacy
  `ZERO_ALLOC / PARTIAL_ALLOC / NO_DISPLAY / NO_DEMAND / NOT_LISTED /
  NO_STOCK` strings the mart pivots on. Even after fixing the column
  name, the mart will return all-zero rows. Needs a rewrite to pivot on
  the actual `R1..R10` set.

### MART_DRILL_SESSION.sql — BLOCKER (2)

- **L21-22 (`alerts_scoped` CTE)**: `SELECT … WERKS, … RULE_CODE …
  FROM MART_ALERTS`. Same `WERKS / STORE` + `RULE_CODE / RULE_ID`
  mismatch as MART_DAILY_ROLLUP. Will fail at compile.
- **L39**: `LISTAGG(DISTINCT RULE_CODE, ',')` — also wrong column name.
  After renaming to `RULE_ID`, double-check the cardinality: the rule
  set emits at most ~9 distinct values per session × store × majcat × gen_art,
  so the default `LISTAGG` budget is fine.

---

## Findings — Worker (worker/src/index.ts)

### HIGH (2)

- **L59 (`/api/alerts/top` SQL)**: `ORDER BY RUN_DATE DESC, SEVERITY_RANK
  ASC NULLS LAST, ALERT_SCORE DESC NULLS LAST`. `MART_ALERTS_TOP` (after
  the column-name fix above) projects `SEVERITY` and `SEVERITY_RANK`
  but no `ALERT_SCORE` column. Query will fail.
  Fix: drop `ALERT_SCORE` from the ORDER BY (or alias `SEVERITY` as
  `ALERT_SCORE` in the view if a public API name is desired).
- **L113 (`/api/drill/sessions` SQL)**: selects
  `ANY_VALUE(FINISHED_AT) AS FINISHED_AT` from `V_SILVER_SESSIONS`. The
  silver view only exposes `STARTED_AT` (plus derived `RUN_DATE` /
  `RUN_HOUR`); there is no `FINISHED_AT` column upstream in
  `ARS_LISTING_SESSIONS` either. Query will fail. Either add
  `FINISHED_AT` to the source schema or remove the column from the
  select list.

---

## Findings — Replication (replication/ars_replicate.py)

### LOW (1)

- **L188 / L201 (`new_high_water`)**: watermark is computed from
  `datetime.utcnow()` *before* the read query has finished, so the
  marker advances past rows that may still be in flight on a long-running
  read. For the chunk sizes used (`100k`) this is benign — but for
  multi-hour future loads, set `new_high_water` after the
  `stream_to_snowflake()` call completes.

No `GETDATE()` references found. The script is Snowflake-on-Python and
talks to SQL Server with parameterised `SELECT * FROM dbo.<table> WHERE
[wm_col] > '<utc-iso>'`, which is portable.

---

## Cross-cutting recommendation

The single largest source of breakage is the `STORE` / `WERKS` and
`RULE_ID` / `RULE_CODE` naming drift between the rule INSERTs (correct)
and every downstream consumer (mart views + worker). Two viable fixes:

1. **Keep the table schema, fix the consumers**. Rename every
   `WERKS` → `STORE` and `RULE_CODE` → `RULE_ID` in the three mart files
   and in `worker/src/index.ts`. Touches 4 files.
2. **Keep the consumers, change the source**. Either rename the
   `MART_ALERTS` columns in `04_mart_alerts.sql` to `WERKS` /
   `RULE_CODE` and update every rule INSERT (9 files), or wrap
   `MART_ALERTS` in a view that aliases them. Touches 10+ files.

Option (1) is the smaller surface area and preserves the cleaner naming
already baked into the rule layer. Recommend resolving before any data
is consumed by the dashboard.

The R3 / R4 / R8 / R9 silver-view gaps (the second-largest cluster) are
all "the silver view does not project the column the rule wants".
Easiest fix is to extend `sql/ddl/03_silver_views.sql`:

- `V_SILVER_LISTING` — add all `*_CONT` and `*_REQ` rollups that
  `ARS_LISTING_HISTORY` already carries, so R3 and R4 can read them.
- `V_SILVER_SESSIONS` — join `ARS_ALLOC_MAJCAT_QUEUE` to expose
  `MAJCAT_STATUS / ERROR_MSG / SHIP_QTY / HOLD_QTY / ATTEMPTS /
  DURATION_SEC` for R9.
- `V_SILVER_ALLOC` — add `RUN_DATE` (derived via the sessions join) for
  R9.
- Add a new `V_SILVER_PEND_ALC` view exposing the raw `ARS_PEND_ALC`
  columns R8 expects.

Once those are in place no rule SQL needs editing.

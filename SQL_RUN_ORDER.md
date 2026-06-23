# SQL_RUN_ORDER

Canonical sequence for running every SQL file in `sql/`. All files are
idempotent (`CREATE … IF NOT EXISTS`, `CREATE OR REPLACE`, or
`DELETE+INSERT` scoped to `RULE_ID` for rules).

Connection (snowsql):

```bash
snowsql -a iafphkw-hh80816 -u akashv2kart -w ALLOC_WH -d V2RETAIL -s ARS_GOLD
```

---

## 1. DDL (one-time per environment; safe to re-run)

| Order | File                                       | What it does                                |
| ----- | ------------------------------------------ | ------------------------------------------- |
| 1.1   | `sql/ddl/01_schemas.sql`                   | Schemas `ARS_BRONZE`, `ARS_GOLD`; watermark |
| 1.2   | `sql/ddl/02_bronze_tables.sql`             | 19 bronze tables (mirror of `Rep_Data`)     |
| 1.3   | `sql/ddl/03_silver_views.sql`              | `V_SILVER_SESSIONS / LISTING / ALLOC / REQUIREMENT / DC_STOCK` |
| 1.4   | `sql/ddl/04_mart_alerts.sql`               | `MART_ALERTS` table                         |

## 2. Rules (run every 30 min after bronze refresh)

| Order | File                                       | Rule weight | LOST_QTY unit |
| ----- | ------------------------------------------ | ----------- | ------------- |
| 2.1   | `sql/rules/R1_MSA_UNALLOC.sql`             | 1.0         | units         |
| 2.2   | `sql/rules/R2_SIZE_MIX_DRIFT.sql`          | 0.7         | units         |
| 2.3   | `sql/rules/R3_ATTR_MIX_DRIFT.sql`          | 0.7         | units         |
| 2.4   | `sql/rules/R4_CAP_BIND.sql`                | 0.9         | units         |
| 2.5   | `sql/rules/R5_DC_OOS_GAP.sql`              | 0.8         | units         |
| 2.6   | `sql/rules/R7_HOLD_HEAVY.sql`              | 0.5         | units (hold)  |
| 2.7   | `sql/rules/R8_BDC_PIPELINE_DEAD.sql`       | 1.5         | units         |
| 2.8   | `sql/rules/R9_MAJCAT_REGRESSION.sql`       | 1.2         | units         |
| 2.9   | `sql/rules/R10_STORE_STARVATION.sql`       | 1.0         | units         |

Rules are independent of each other — order does not matter for correctness,
but the listing above is the order `make rules` runs them in.

Note: there is no `R6` file. The rule numbering reserves R6 for a future
NO_DEMAND_BLOCKED detector; the gap is intentional.

## 3. Marts (refresh after every rule run)

| Order | File                                       | Output                              |
| ----- | ------------------------------------------ | ----------------------------------- |
| 3.1   | `sql/marts/MART_ALERTS_TOP.sql`            | `MART_ALERTS_TOP` view (UI today)   |
| 3.2   | `sql/marts/MART_DAILY_ROLLUP.sql`          | `MART_DAILY_ROLLUP` view (UI trends)|
| 3.3   | `sql/marts/MART_DRILL_SESSION.sql`         | `MART_DRILL_SESSION` view (UI drill)|

---

## Re-run shortcuts

```bash
make schemas      # 1.1 - 1.4
make rules        # 2.1 - 2.9
make marts        # 3.1 - 3.3
make refresh      # rules + marts (post-replication cron target)
```

## Verification

```sql
-- per-rule alert counts (latest window)
SELECT RULE_ID, COUNT(*) AS alerts, SUM(SEVERITY) AS severity_sum
FROM V2RETAIL.ARS_GOLD.MART_ALERTS
WHERE RUN_DATE >= DATEADD('day', -1, CURRENT_DATE)
GROUP BY RULE_ID
ORDER BY RULE_ID;

-- latest run date covered
SELECT MAX(RUN_DATE) FROM V2RETAIL.ARS_GOLD.MART_ALERTS;
```

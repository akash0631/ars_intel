-- ============================================================================
-- MART_DAILY_ROLLUP
-- ----------------------------------------------------------------------------
-- Daily KPI rollup per detector RULE_ID from V2RETAIL.ARS_GOLD.MART_ALERTS.
-- One row per RUN_DATE; one column-group per rule (pivoted via conditional agg).
--
-- KPIs per rule:
--   alert_count       count of alerts
--   total_lost_qty    SUM(LOST_QTY)
--   total_severity    SUM(SEVERITY)
--   p90_severity      PERCENTILE_CONT(0.9) within rule
--   distinct_stores   COUNT(DISTINCT STORE)
--   distinct_majcats  COUNT(DISTINCT MAJ_CAT)
--
-- Rules emitted by the detector layer: R1, R2, R3, R4, R5, R7, R8, R9, R10.
-- ============================================================================

CREATE OR REPLACE VIEW V2RETAIL.ARS_GOLD.MART_DAILY_ROLLUP AS
WITH per_rule AS (
    SELECT
        RUN_DATE,
        RULE_ID,
        COUNT(*)                              AS alert_count,
        SUM(COALESCE(LOST_QTY, 0))            AS total_lost_qty,
        SUM(COALESCE(SEVERITY, 0))            AS total_severity,
        PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY SEVERITY) AS p90_severity,
        COUNT(DISTINCT STORE)                 AS distinct_stores,
        COUNT(DISTINCT MAJ_CAT)               AS distinct_majcats
    FROM V2RETAIL.ARS_GOLD.MART_ALERTS
    WHERE RUN_DATE >= DATEADD(day, -90, CURRENT_DATE())
    GROUP BY RUN_DATE, RULE_ID
)
SELECT
    RUN_DATE,

    -- ---------- R1 MSA_UNALLOC ----------
    SUM(CASE WHEN RULE_ID = 'R1' THEN alert_count      ELSE 0 END) AS R1_alert_count,
    SUM(CASE WHEN RULE_ID = 'R1' THEN total_lost_qty   ELSE 0 END) AS R1_total_lost_qty,
    SUM(CASE WHEN RULE_ID = 'R1' THEN total_severity   ELSE 0 END) AS R1_total_severity,
    MAX(CASE WHEN RULE_ID = 'R1' THEN p90_severity     END)        AS R1_p90_severity,
    SUM(CASE WHEN RULE_ID = 'R1' THEN distinct_stores  ELSE 0 END) AS R1_distinct_stores,
    SUM(CASE WHEN RULE_ID = 'R1' THEN distinct_majcats ELSE 0 END) AS R1_distinct_majcats,

    -- ---------- R2 SIZE_MIX_DRIFT ----------
    SUM(CASE WHEN RULE_ID = 'R2' THEN alert_count      ELSE 0 END) AS R2_alert_count,
    SUM(CASE WHEN RULE_ID = 'R2' THEN total_lost_qty   ELSE 0 END) AS R2_total_lost_qty,
    SUM(CASE WHEN RULE_ID = 'R2' THEN total_severity   ELSE 0 END) AS R2_total_severity,
    MAX(CASE WHEN RULE_ID = 'R2' THEN p90_severity     END)        AS R2_p90_severity,
    SUM(CASE WHEN RULE_ID = 'R2' THEN distinct_stores  ELSE 0 END) AS R2_distinct_stores,
    SUM(CASE WHEN RULE_ID = 'R2' THEN distinct_majcats ELSE 0 END) AS R2_distinct_majcats,

    -- ---------- R3 ATTR_MIX_DRIFT ----------
    SUM(CASE WHEN RULE_ID = 'R3' THEN alert_count      ELSE 0 END) AS R3_alert_count,
    SUM(CASE WHEN RULE_ID = 'R3' THEN total_lost_qty   ELSE 0 END) AS R3_total_lost_qty,
    SUM(CASE WHEN RULE_ID = 'R3' THEN total_severity   ELSE 0 END) AS R3_total_severity,
    MAX(CASE WHEN RULE_ID = 'R3' THEN p90_severity     END)        AS R3_p90_severity,
    SUM(CASE WHEN RULE_ID = 'R3' THEN distinct_stores  ELSE 0 END) AS R3_distinct_stores,
    SUM(CASE WHEN RULE_ID = 'R3' THEN distinct_majcats ELSE 0 END) AS R3_distinct_majcats,

    -- ---------- R4 CAP_BIND ----------
    SUM(CASE WHEN RULE_ID = 'R4' THEN alert_count      ELSE 0 END) AS R4_alert_count,
    SUM(CASE WHEN RULE_ID = 'R4' THEN total_lost_qty   ELSE 0 END) AS R4_total_lost_qty,
    SUM(CASE WHEN RULE_ID = 'R4' THEN total_severity   ELSE 0 END) AS R4_total_severity,
    MAX(CASE WHEN RULE_ID = 'R4' THEN p90_severity     END)        AS R4_p90_severity,
    SUM(CASE WHEN RULE_ID = 'R4' THEN distinct_stores  ELSE 0 END) AS R4_distinct_stores,
    SUM(CASE WHEN RULE_ID = 'R4' THEN distinct_majcats ELSE 0 END) AS R4_distinct_majcats,

    -- ---------- R5 DC_OOS_GAP ----------
    SUM(CASE WHEN RULE_ID = 'R5' THEN alert_count      ELSE 0 END) AS R5_alert_count,
    SUM(CASE WHEN RULE_ID = 'R5' THEN total_lost_qty   ELSE 0 END) AS R5_total_lost_qty,
    SUM(CASE WHEN RULE_ID = 'R5' THEN total_severity   ELSE 0 END) AS R5_total_severity,
    MAX(CASE WHEN RULE_ID = 'R5' THEN p90_severity     END)        AS R5_p90_severity,
    SUM(CASE WHEN RULE_ID = 'R5' THEN distinct_stores  ELSE 0 END) AS R5_distinct_stores,
    SUM(CASE WHEN RULE_ID = 'R5' THEN distinct_majcats ELSE 0 END) AS R5_distinct_majcats,

    -- ---------- R7 HOLD_HEAVY ----------
    SUM(CASE WHEN RULE_ID = 'R7' THEN alert_count      ELSE 0 END) AS R7_alert_count,
    SUM(CASE WHEN RULE_ID = 'R7' THEN total_lost_qty   ELSE 0 END) AS R7_total_lost_qty,
    SUM(CASE WHEN RULE_ID = 'R7' THEN total_severity   ELSE 0 END) AS R7_total_severity,
    MAX(CASE WHEN RULE_ID = 'R7' THEN p90_severity     END)        AS R7_p90_severity,
    SUM(CASE WHEN RULE_ID = 'R7' THEN distinct_stores  ELSE 0 END) AS R7_distinct_stores,
    SUM(CASE WHEN RULE_ID = 'R7' THEN distinct_majcats ELSE 0 END) AS R7_distinct_majcats,

    -- ---------- R8 BDC_PIPELINE_DEAD ----------
    SUM(CASE WHEN RULE_ID = 'R8' THEN alert_count      ELSE 0 END) AS R8_alert_count,
    SUM(CASE WHEN RULE_ID = 'R8' THEN total_lost_qty   ELSE 0 END) AS R8_total_lost_qty,
    SUM(CASE WHEN RULE_ID = 'R8' THEN total_severity   ELSE 0 END) AS R8_total_severity,
    MAX(CASE WHEN RULE_ID = 'R8' THEN p90_severity     END)        AS R8_p90_severity,
    SUM(CASE WHEN RULE_ID = 'R8' THEN distinct_stores  ELSE 0 END) AS R8_distinct_stores,
    SUM(CASE WHEN RULE_ID = 'R8' THEN distinct_majcats ELSE 0 END) AS R8_distinct_majcats,

    -- ---------- R9 MAJCAT_REGRESSION ----------
    SUM(CASE WHEN RULE_ID = 'R9' THEN alert_count      ELSE 0 END) AS R9_alert_count,
    SUM(CASE WHEN RULE_ID = 'R9' THEN total_lost_qty   ELSE 0 END) AS R9_total_lost_qty,
    SUM(CASE WHEN RULE_ID = 'R9' THEN total_severity   ELSE 0 END) AS R9_total_severity,
    MAX(CASE WHEN RULE_ID = 'R9' THEN p90_severity     END)        AS R9_p90_severity,
    SUM(CASE WHEN RULE_ID = 'R9' THEN distinct_stores  ELSE 0 END) AS R9_distinct_stores,
    SUM(CASE WHEN RULE_ID = 'R9' THEN distinct_majcats ELSE 0 END) AS R9_distinct_majcats,

    -- ---------- R10 STORE_STARVATION ----------
    SUM(CASE WHEN RULE_ID = 'R10' THEN alert_count      ELSE 0 END) AS R10_alert_count,
    SUM(CASE WHEN RULE_ID = 'R10' THEN total_lost_qty   ELSE 0 END) AS R10_total_lost_qty,
    SUM(CASE WHEN RULE_ID = 'R10' THEN total_severity   ELSE 0 END) AS R10_total_severity,
    MAX(CASE WHEN RULE_ID = 'R10' THEN p90_severity     END)        AS R10_p90_severity,
    SUM(CASE WHEN RULE_ID = 'R10' THEN distinct_stores  ELSE 0 END) AS R10_distinct_stores,
    SUM(CASE WHEN RULE_ID = 'R10' THEN distinct_majcats ELSE 0 END) AS R10_distinct_majcats,

    -- ---------- totals ----------
    SUM(alert_count)      AS ALL_alert_count,
    SUM(total_lost_qty)   AS ALL_total_lost_qty,
    SUM(total_severity)   AS ALL_total_severity,
    MAX(p90_severity)     AS ALL_p90_severity_max,
    SUM(distinct_stores)  AS ALL_distinct_stores_sum,
    SUM(distinct_majcats) AS ALL_distinct_majcats_sum

FROM per_rule
GROUP BY RUN_DATE
ORDER BY RUN_DATE DESC;

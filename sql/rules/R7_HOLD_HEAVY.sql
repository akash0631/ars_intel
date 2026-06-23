-- =============================================================================
-- Rule:        R7_HOLD_HEAVY
-- Purpose:     Detect majcats within a session where the HOLD ratio exceeds 30%.
--              When HOLD_QTY / (SHIP_QTY + HOLD_QTY) > 0.30 for a given
--              (session, maj_cat), allocation is producing too much hold vs. ship
--              -- pointing at constrained DC stock, over-aggressive caps, or
--              majcat-level demand vs. supply mismatch.
--
-- lost_qty:    HOLD_QTY at the (session, maj_cat) grain. We treat the held
--              quantity as the "lost" ship opportunity because it is demand
--              that the allocator could not satisfy in this run.
--
-- Severity:    severity = lost_qty
--                       * store_priority   -- N/A at majcat grain, fallback 0.5
--                       * majcat_priority  -- majcat ship contribution % over
--                                             trailing 30d from V_SILVER_ALLOC
--                       * recency_decay    -- POWER(0.95, days since RUN_DATE)
--                       * 0.5              -- rule weight
--
-- Notes:
--   - Aggregates at (SESSION_ID, MAJ_CAT) grain. STORE / GEN_ART / VAR_ART /
--     ATTR_DIM / ATTR_VAL are NULL since this is a majcat-level signal.
--   - ALLOC_REASON is NULL in source; we infer from the silver allocation view.
--   - Reads only from V2RETAIL.ARS_GOLD silver views (no BRONZE access).
--   - Idempotent via DELETE on RULE_ID='R7' for the in-scope sessions.
-- =============================================================================

DELETE FROM V2RETAIL.ARS_GOLD.MART_ALERTS
WHERE RULE_ID = 'R7'
  AND SESSION_ID IN (
    SELECT s.SESSION_ID
    FROM V2RETAIL.ARS_GOLD.V_SILVER_SESSIONS s
    WHERE s.STATUS = 'SUCCESS'
      AND s.STARTED_AT >= DATEADD('day', -7, CURRENT_DATE)
  );

INSERT INTO V2RETAIL.ARS_GOLD.MART_ALERTS (
    RULE_ID,
    SESSION_ID,
    RUN_DATE,
    STORE,
    MAJ_CAT,
    GEN_ART_NUMBER,
    VAR_ART,
    ATTR_DIM,
    ATTR_VAL,
    LOST_QTY,
    ROOT_CAUSE,
    FIX_ACTION,
    SEVERITY,
    DETAIL_JSON
)
WITH in_scope_sessions AS (
    SELECT
        s.SESSION_ID,
        CAST(s.STARTED_AT AS DATE) AS RUN_DATE
    FROM V2RETAIL.ARS_GOLD.V_SILVER_SESSIONS s
    WHERE s.STATUS = 'SUCCESS'
      AND s.STARTED_AT >= DATEADD('day', -7, CURRENT_DATE)
),
session_majcat_agg AS (
    SELECT
        a.SESSION_ID,
        a.MAJ_CAT,
        SUM(COALESCE(a.SHIP_QTY, 0))              AS SHIP_QTY,
        SUM(COALESCE(a.HOLD_QTY, 0))              AS HOLD_QTY,
        SUM(COALESCE(a.ALLOC_QTY, 0))             AS ALLOC_QTY,
        COUNT(DISTINCT a.WERKS)                   AS STORE_COUNT,
        COUNT(DISTINCT a.GEN_ART_NUMBER)          AS GEN_ART_COUNT,
        COUNT(*)                                  AS ALLOC_ROWS
    FROM V2RETAIL.ARS_GOLD.V_SILVER_ALLOC a
    JOIN in_scope_sessions iss
      ON iss.SESSION_ID = a.SESSION_ID
    WHERE a.MAJ_CAT IS NOT NULL
    GROUP BY a.SESSION_ID, a.MAJ_CAT
),
flagged AS (
    SELECT
        sma.SESSION_ID,
        sma.MAJ_CAT,
        sma.SHIP_QTY,
        sma.HOLD_QTY,
        sma.ALLOC_QTY,
        sma.STORE_COUNT,
        sma.GEN_ART_COUNT,
        sma.ALLOC_ROWS,
        sma.HOLD_QTY / NULLIF(sma.SHIP_QTY + sma.HOLD_QTY, 0) AS HOLD_RATIO,
        iss.RUN_DATE
    FROM session_majcat_agg sma
    JOIN in_scope_sessions iss
      ON iss.SESSION_ID = sma.SESSION_ID
    WHERE (sma.SHIP_QTY + sma.HOLD_QTY) > 0
      AND (sma.HOLD_QTY / NULLIF(sma.SHIP_QTY + sma.HOLD_QTY, 0)) > 0.30
),
-- Majcat priority = majcat ship contribution % over trailing 30d, inline from
-- V_SILVER_ALLOC. Fallback 0.5 if a majcat has no trailing-30d ship signal.
majcat_ship_30d AS (
    SELECT
        a.MAJ_CAT,
        SUM(COALESCE(a.SHIP_QTY, 0)) AS MAJCAT_SHIP_30D
    FROM V2RETAIL.ARS_GOLD.V_SILVER_ALLOC a
    JOIN V2RETAIL.ARS_GOLD.V_SILVER_SESSIONS s
      ON s.SESSION_ID = a.SESSION_ID
    WHERE s.STARTED_AT >= DATEADD('day', -30, CURRENT_DATE)
      AND s.STATUS = 'SUCCESS'
      AND a.MAJ_CAT IS NOT NULL
    GROUP BY a.MAJ_CAT
),
total_ship_30d AS (
    SELECT SUM(MAJCAT_SHIP_30D) AS TOTAL_SHIP_30D
    FROM majcat_ship_30d
),
majcat_priority AS (
    SELECT
        m.MAJ_CAT,
        COALESCE(
            m.MAJCAT_SHIP_30D / NULLIF(t.TOTAL_SHIP_30D, 0),
            0.5
        ) AS MAJCAT_PRIORITY
    FROM majcat_ship_30d m
    CROSS JOIN total_ship_30d t
)
SELECT
    'R7'                                                    AS RULE_ID,
    f.SESSION_ID                                            AS SESSION_ID,
    f.RUN_DATE                                              AS RUN_DATE,
    CAST(NULL AS VARCHAR)                                   AS STORE,
    f.MAJ_CAT                                               AS MAJ_CAT,
    CAST(NULL AS VARCHAR)                                   AS GEN_ART_NUMBER,
    CAST(NULL AS VARCHAR)                                   AS VAR_ART,
    CAST(NULL AS VARCHAR)                                   AS ATTR_DIM,
    CAST(NULL AS VARCHAR)                                   AS ATTR_VAL,
    f.HOLD_QTY                                              AS LOST_QTY,
    CASE
        WHEN f.HOLD_RATIO >= 0.70 THEN
            'Severe hold: ' || ROUND(f.HOLD_RATIO * 100, 1) ||
            '% of majcat allocation parked in hold -- DC stock or cap constraints choking ' || f.MAJ_CAT
        WHEN f.HOLD_RATIO >= 0.50 THEN
            'High hold ratio ' || ROUND(f.HOLD_RATIO * 100, 1) ||
            '% on ' || f.MAJ_CAT || ' -- allocator unable to ship majority of demand'
        ELSE
            'Elevated hold ratio ' || ROUND(f.HOLD_RATIO * 100, 1) ||
            '% on ' || f.MAJ_CAT || ' -- demand exceeds available ship capacity'
    END                                                     AS ROOT_CAUSE,
    CASE
        WHEN f.HOLD_RATIO >= 0.70 THEN 'escalate'
        WHEN f.HOLD_RATIO >= 0.50 THEN 'dc_redistribute'
        ELSE 'lift_cap'
    END                                                     AS FIX_ACTION,
    (
        f.HOLD_QTY
        * 0.5
        * COALESCE(mp.MAJCAT_PRIORITY, 0.5)
        * POWER(0.95, DATEDIFF('day', f.RUN_DATE, CURRENT_DATE))
        * 0.5
    )                                                       AS SEVERITY,
    OBJECT_CONSTRUCT(
        'rule_id',          'R7',
        'rule_name',        'HOLD_HEAVY',
        'session_id',       f.SESSION_ID,
        'maj_cat',          f.MAJ_CAT,
        'ship_qty',         f.SHIP_QTY,
        'hold_qty',         f.HOLD_QTY,
        'alloc_qty',        f.ALLOC_QTY,
        'hold_ratio',       ROUND(f.HOLD_RATIO, 4),
        'threshold',        0.30,
        'store_count',      f.STORE_COUNT,
        'gen_art_count',    f.GEN_ART_COUNT,
        'alloc_rows',       f.ALLOC_ROWS,
        'majcat_priority',  ROUND(COALESCE(mp.MAJCAT_PRIORITY, 0.5), 6),
        'store_priority',   0.5,
        'recency_decay',    ROUND(POWER(0.95, DATEDIFF('day', f.RUN_DATE, CURRENT_DATE)), 6),
        'rule_weight',      0.5,
        'inferred_reason',  'ALLOC_REASON NULL in source; inferred from session-majcat HOLD vs SHIP aggregation in V_SILVER_ALLOC'
    )                                                       AS DETAIL_JSON
FROM flagged f
LEFT JOIN majcat_priority mp
  ON mp.MAJ_CAT = f.MAJ_CAT;

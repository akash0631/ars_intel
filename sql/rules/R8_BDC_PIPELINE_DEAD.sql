-- =====================================================================
-- Rule R8: BDC_PIPELINE_DEAD
-- ---------------------------------------------------------------------
-- Detects that the BDC (downstream delivery / despatch confirmation)
-- pipeline has stalled. ARS approves allocations into ARS_pend_alc, the
-- BDC job is supposed to acknowledge them downstream. When BDC_QTY stays
-- at 0 across a large pool of recently-approved-still-open rows, the
-- pipeline is effectively dead and physical movement is not happening.
--
-- Trigger: total open approved-without-BDC qty (last 24h) > 100,000.
-- Scope:   single NATIONAL alert (STORE / MAJ_CAT / GEN_ART = NULL).
--
-- lost_qty meaning: total approved qty stuck without BDC acknowledgement
--                   in the last 24h. This is the dispatch backlog that
--                   is silently rotting.
--
-- Severity formula:
--   severity = lost_qty
--            * store_priority   (national => use 1.0)
--            * majcat_priority  (national => use 1.0)
--            * recency_decay    (POWER(0.95, days since RUN_DATE))
--            * 1.5              (rule weight)
--
-- Source: V2RETAIL.ARS_GOLD silver views only (no BRONZE).
-- ALLOC_REASON is always NULL in source; we infer from the join.
-- =====================================================================

DELETE FROM V2RETAIL.ARS_GOLD.MART_ALERTS
WHERE RULE_ID = 'R8'
  AND SESSION_ID IN (
    SELECT SESSION_ID
    FROM V2RETAIL.ARS_GOLD.V_SILVER_SESSIONS
    WHERE STARTED_AT >= DATEADD('day', -1, CURRENT_DATE)
      AND STATUS = 'SUCCESS'
  );

INSERT INTO V2RETAIL.ARS_GOLD.MART_ALERTS (
  RULE_ID, SESSION_ID, RUN_DATE, STORE, MAJ_CAT, GEN_ART_NUMBER, VAR_ART,
  ATTR_DIM, ATTR_VAL, LOST_QTY, ROOT_CAUSE, FIX_ACTION, SEVERITY, DETAIL_JSON
)
WITH
-- Latest successful ARS session within the last 24h drives the alert
latest_session AS (
  SELECT
    SESSION_ID,
    CAST(STARTED_AT AS DATE) AS RUN_DATE
  FROM V2RETAIL.ARS_GOLD.V_SILVER_SESSIONS
  WHERE STATUS = 'SUCCESS'
    AND STARTED_AT >= DATEADD('day', -1, CURRENT_DATE)
  QUALIFY ROW_NUMBER() OVER (ORDER BY STARTED_AT DESC) = 1
),
-- Pull the open approved-without-BDC rows from the pending allocation
-- silver view. These are rows where ARS said "go" but downstream BDC
-- never acknowledged.
stuck_rows AS (
  SELECT
    p.ST_CD                  AS WERKS,
    p.MAJ_CAT,
    p.GEN_ART_NUMBER,
    p.ARTICLE_NUMBER         AS VAR_ART,
    IFNULL(p.QTY, 0)         AS QTY,
    p.APPROVED_AT,
    p.LAST_BDC_AT
  FROM V2RETAIL.ARS_GOLD.V_SILVER_PEND_ALC p
  WHERE p.APPROVED_AT > DATEADD('day', -1, CURRENT_DATE)
    AND IFNULL(p.IS_CLOSED, 0) = 0
    AND IFNULL(p.BDC_QTY, 0)   = 0
),
-- Per-store rollup (used inside DETAIL_JSON for diagnostics)
per_store AS (
  SELECT
    WERKS,
    SUM(QTY)                                       AS STORE_LOST_QTY,
    COUNT(*)                                       AS STORE_ROWS,
    COUNT(DISTINCT MAJ_CAT)                        AS MAJCATS,
    COUNT(DISTINCT GEN_ART_NUMBER)                 AS GEN_ARTS,
    MAX(APPROVED_AT)                               AS LAST_APPROVED_AT,
    MAX(LAST_BDC_AT)                               AS LAST_BDC_AT
  FROM stuck_rows
  GROUP BY WERKS
),
-- National total
national AS (
  SELECT
    SUM(STORE_LOST_QTY) AS TOTAL_LOST_QTY,
    COUNT(*)            AS STORE_COUNT,
    SUM(STORE_ROWS)     AS TOTAL_ROWS
  FROM per_store
),
-- Top offender stores for the JSON payload
top_stores AS (
  SELECT
    ARRAY_AGG(
      OBJECT_CONSTRUCT(
        'werks',           WERKS,
        'lost_qty',        STORE_LOST_QTY,
        'rows',            STORE_ROWS,
        'majcats',         MAJCATS,
        'gen_arts',        GEN_ARTS,
        'last_approved',   LAST_APPROVED_AT,
        'last_bdc',        LAST_BDC_AT
      )
    ) WITHIN GROUP (ORDER BY STORE_LOST_QTY DESC) AS STORE_BREAKDOWN
  FROM (
    SELECT *
    FROM per_store
    ORDER BY STORE_LOST_QTY DESC
    LIMIT 25
  )
),
-- Recency decay: 1.0 today, 0.95 yesterday, etc.
decay AS (
  SELECT POWER(0.95, DATEDIFF('day', RUN_DATE, CURRENT_DATE)) AS RECENCY_DECAY
  FROM latest_session
)
SELECT
  'R8'                                       AS RULE_ID,
  ls.SESSION_ID                              AS SESSION_ID,
  ls.RUN_DATE                                AS RUN_DATE,
  NULL                                       AS STORE,              -- national alert
  NULL                                       AS MAJ_CAT,
  NULL                                       AS GEN_ART_NUMBER,
  NULL                                       AS VAR_ART,
  'PIPELINE'                                 AS ATTR_DIM,
  'BDC'                                      AS ATTR_VAL,
  n.TOTAL_LOST_QTY                           AS LOST_QTY,
  'BDC pipeline appears dead: '
    || n.TOTAL_LOST_QTY
    || ' qty approved in last 24h across '
    || n.STORE_COUNT
    || ' stores has zero BDC acknowledgement. '
    || 'Downstream despatch confirmation has stopped flowing back to ARS.'
                                              AS ROOT_CAUSE,
  'escalate'                                 AS FIX_ACTION,
  CAST(
      n.TOTAL_LOST_QTY
    * 1.0                                       -- national: store_priority = 1.0
    * 1.0                                       -- national: majcat_priority = 1.0
    * d.RECENCY_DECAY
    * 1.5                                       -- rule weight R8
    AS FLOAT
  )                                          AS SEVERITY,
  OBJECT_CONSTRUCT(
    'rule',                 'R8',
    'rule_name',            'BDC_PIPELINE_DEAD',
    'scope',                'NATIONAL',
    'threshold_qty',        100000,
    'total_lost_qty',       n.TOTAL_LOST_QTY,
    'store_count',          n.STORE_COUNT,
    'total_rows',           n.TOTAL_ROWS,
    'window_hours',         24,
    'inferred_reason',      'BDC_QTY=0 across all approved-open rows in window (ALLOC_REASON is NULL in source)',
    'recency_decay',        d.RECENCY_DECAY,
    'rule_weight',          1.5,
    'store_priority_used',  1.0,
    'majcat_priority_used', 1.0,
    'top_stores',           ts.STORE_BREAKDOWN
  )                                          AS DETAIL_JSON
FROM national n
CROSS JOIN latest_session ls
CROSS JOIN decay d
CROSS JOIN top_stores ts
WHERE n.TOTAL_LOST_QTY > 100000;

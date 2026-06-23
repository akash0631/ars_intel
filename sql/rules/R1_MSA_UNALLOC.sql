-- =====================================================================
-- Rule R1: MSA_UNALLOC
-- ---------------------------------------------------------------------
-- Detects store x major-category combinations where:
--   * Major-category requirement (MJ_REQ) > 0
--   * An eligible (ELIG_FLAG=1, ELIG_REASON='OK') MSA gen-article exists
--     in the listing for that store-majcat
--   * Yet there is NO corresponding ALLOC_HISTORY ship row (or all
--     candidate rows landed in SKIPPED status)
--
-- lost_qty meaning:
--   For each (SESSION_ID, STORE, MAJ_CAT) we take MAX(MJ_REQ) from
--   listing (MJ_REQ is repeated per gen-art row inside the same
--   store-majcat) and subtract whatever SHIP_QTY actually went out
--   from ALLOC_HISTORY for that store-majcat (across all gen-arts).
--   lost_qty = GREATEST(mj_req - allocated_qty, 0)
--
-- Severity:
--   severity = lost_qty
--            * store_priority      (normalized ST_RANK, fallback 0.5)
--            * majcat_priority     (majcat ship share trailing 30d, fallback 0.5)
--            * recency_decay       (POWER(0.95, days since RUN_DATE))
--            * 1                   (rule weight)
--
-- Notes:
--   * Reads ONLY from V2RETAIL.ARS_GOLD silver views.
--   * ALLOC_REASON is always NULL in source; we INFER cause from joins.
--   * Idempotent: deletes its own RULE_ID rows for the SESSION scope
--     before re-inserting.
-- =====================================================================

DELETE FROM V2RETAIL.ARS_GOLD.MART_ALERTS
WHERE RULE_ID = 'R1'
  AND SESSION_ID IN (
    SELECT SESSION_ID
    FROM V2RETAIL.ARS_GOLD.V_SILVER_SESSIONS
    WHERE STATUS = 'SUCCESS'
      AND STARTED_AT >= DATEADD('day', -7, CURRENT_DATE)
  );

INSERT INTO V2RETAIL.ARS_GOLD.MART_ALERTS (
  RULE_ID, SESSION_ID, RUN_DATE, STORE, MAJ_CAT, GEN_ART_NUMBER,
  VAR_ART, ATTR_DIM, ATTR_VAL, LOST_QTY, ROOT_CAUSE, FIX_ACTION,
  SEVERITY, DETAIL_JSON
)
WITH sessions AS (
  -- Scope: last 7 days of SUCCESS sessions
  SELECT
    SESSION_ID,
    CAST(STARTED_AT AS DATE) AS RUN_DATE,
    STARTED_AT
  FROM V2RETAIL.ARS_GOLD.V_SILVER_SESSIONS
  WHERE STATUS = 'SUCCESS'
    AND STARTED_AT >= DATEADD('day', -7, CURRENT_DATE)
),
listing AS (
  -- Eligible MSA gen-art rows from silver listing
  SELECT
    l.SESSION_ID,
    l.WERKS                AS STORE,
    l.MAJ_CAT,
    l.GEN_ART_NUMBER,
    l.MJ_REQ,
    l.ST_RANK,
    l.ELIG_FLAG,
    l.ELIG_REASON,
    l.MSA_FNL_Q,
    l.OPT_TYPE
  FROM V2RETAIL.ARS_GOLD.V_SILVER_LISTING l
  JOIN sessions s ON s.SESSION_ID = l.SESSION_ID
),
-- Roll up requirement and eligibility flags to (session, store, majcat)
store_majcat AS (
  SELECT
    SESSION_ID,
    STORE,
    MAJ_CAT,
    MAX(MJ_REQ)                                                   AS MJ_REQ,
    MAX(CASE WHEN ELIG_FLAG = 1 AND ELIG_REASON = 'OK' THEN 1 ELSE 0 END)
                                                                  AS HAS_ELIG_MSA,
    COUNT_IF(ELIG_FLAG = 1 AND ELIG_REASON = 'OK')                AS ELIG_GEN_ART_COUNT,
    COUNT(*)                                                       AS TOTAL_GEN_ART_COUNT,
    MAX(ST_RANK)                                                  AS ST_RANK,
    -- pick one representative eligible gen-art for the alert payload
    MAX(CASE WHEN ELIG_FLAG = 1 AND ELIG_REASON = 'OK'
             THEN GEN_ART_NUMBER END)                             AS SAMPLE_GEN_ART
  FROM listing
  GROUP BY SESSION_ID, STORE, MAJ_CAT
),
-- Allocated qty per store x majcat from silver alloc
alloc_rollup AS (
  SELECT
    a.SESSION_ID,
    a.WERKS                       AS STORE,
    l.MAJ_CAT,
    SUM(COALESCE(a.SHIP_QTY, 0))  AS SHIPPED_QTY,
    SUM(COALESCE(a.ALLOC_QTY, 0)) AS ALLOC_QTY_TOTAL,
    COUNT_IF(a.ALLOC_STATUS IN ('ALLOCATED', 'PARTIAL'))   AS ALLOC_ROWS_OK,
    COUNT_IF(a.ALLOC_STATUS = 'SKIPPED')                   AS ALLOC_ROWS_SKIPPED,
    COUNT(*)                                               AS ALLOC_ROWS_TOTAL
  FROM V2RETAIL.ARS_GOLD.V_SILVER_ALLOC a
  JOIN (
    SELECT DISTINCT SESSION_ID, WERKS AS STORE, GEN_ART_NUMBER, MAJ_CAT
    FROM V2RETAIL.ARS_GOLD.V_SILVER_LISTING
  ) l
    ON l.SESSION_ID     = a.SESSION_ID
   AND l.STORE          = a.WERKS
   AND l.GEN_ART_NUMBER = a.GEN_ART_NUMBER
  JOIN sessions s ON s.SESSION_ID = a.SESSION_ID
  GROUP BY a.SESSION_ID, a.WERKS, l.MAJ_CAT
),
-- Store priority: normalized ST_RANK (lower rank = higher priority).
-- We normalize within session so best store -> 1.0, worst -> ~0.
store_rank_norm AS (
  SELECT
    SESSION_ID,
    STORE,
    ST_RANK,
    CASE
      WHEN ST_RANK IS NULL THEN 0.5
      WHEN MAX(ST_RANK) OVER (PARTITION BY SESSION_ID)
         = MIN(ST_RANK) OVER (PARTITION BY SESSION_ID) THEN 0.5
      ELSE 1.0 - (
        (ST_RANK - MIN(ST_RANK) OVER (PARTITION BY SESSION_ID))
        /
        NULLIF(
          MAX(ST_RANK) OVER (PARTITION BY SESSION_ID)
        - MIN(ST_RANK) OVER (PARTITION BY SESSION_ID), 0)
      )
    END                                                         AS STORE_PRIORITY
  FROM (
    SELECT DISTINCT SESSION_ID, STORE, ST_RANK
    FROM listing
  )
),
-- Majcat priority: share of ship qty contributed by this majcat over
-- trailing 30d of alloc, inferred via listing join (alloc lacks MAJ_CAT).
majcat_share_30d AS (
  SELECT
    l.MAJ_CAT,
    SUM(COALESCE(a.SHIP_QTY, 0))   AS MJ_SHIP_30D
  FROM V2RETAIL.ARS_GOLD.V_SILVER_ALLOC a
  JOIN V2RETAIL.ARS_GOLD.V_SILVER_SESSIONS s
    ON s.SESSION_ID = a.SESSION_ID
   AND s.STATUS = 'SUCCESS'
   AND s.STARTED_AT >= DATEADD('day', -30, CURRENT_DATE)
  JOIN (
    SELECT DISTINCT SESSION_ID, WERKS AS STORE, GEN_ART_NUMBER, MAJ_CAT
    FROM V2RETAIL.ARS_GOLD.V_SILVER_LISTING
  ) l
    ON l.SESSION_ID     = a.SESSION_ID
   AND l.STORE          = a.WERKS
   AND l.GEN_ART_NUMBER = a.GEN_ART_NUMBER
  GROUP BY l.MAJ_CAT
),
majcat_priority AS (
  SELECT
    MAJ_CAT,
    CASE
      WHEN SUM(MJ_SHIP_30D) OVER () IS NULL
        OR SUM(MJ_SHIP_30D) OVER () = 0 THEN 0.5
      ELSE MJ_SHIP_30D / SUM(MJ_SHIP_30D) OVER ()
    END                                                         AS MAJCAT_PRIORITY
  FROM majcat_share_30d
)
SELECT
  'R1'                                                          AS RULE_ID,
  sm.SESSION_ID,
  s.RUN_DATE,
  sm.STORE,
  sm.MAJ_CAT,
  sm.SAMPLE_GEN_ART                                             AS GEN_ART_NUMBER,
  CAST(NULL AS STRING)                                          AS VAR_ART,
  CAST(NULL AS STRING)                                          AS ATTR_DIM,
  CAST(NULL AS STRING)                                          AS ATTR_VAL,
  GREATEST(
    COALESCE(sm.MJ_REQ, 0) - COALESCE(ar.SHIPPED_QTY, 0),
    0
  )                                                             AS LOST_QTY,
  CASE
    WHEN ar.SESSION_ID IS NULL THEN
      'MSA major-category requirement of '
      || COALESCE(sm.MJ_REQ::STRING, '0')
      || ' units never reached allocator: 0 ship rows for store '
      || sm.STORE || ' / majcat ' || sm.MAJ_CAT
      || ' despite ' || sm.ELIG_GEN_ART_COUNT::STRING
      || ' eligible (ELIG=OK) gen-articles in listing'
    WHEN ar.ALLOC_ROWS_OK = 0 AND ar.ALLOC_ROWS_SKIPPED > 0 THEN
      'All ' || ar.ALLOC_ROWS_SKIPPED::STRING
      || ' alloc rows for store ' || sm.STORE
      || ' / majcat ' || sm.MAJ_CAT
      || ' landed in SKIPPED status; MJ_REQ='
      || COALESCE(sm.MJ_REQ::STRING, '0')
      || ' fully lost (eligible gen-arts existed)'
    ELSE
      'Partial MSA underfill: shipped '
      || COALESCE(ar.SHIPPED_QTY::STRING, '0')
      || ' of MJ_REQ ' || COALESCE(sm.MJ_REQ::STRING, '0')
      || ' for store ' || sm.STORE || ' / majcat ' || sm.MAJ_CAT
  END                                                           AS ROOT_CAUSE,
  CASE
    WHEN ar.SESSION_ID IS NULL                  THEN 'investigate'
    WHEN ar.ALLOC_ROWS_OK = 0
     AND ar.ALLOC_ROWS_SKIPPED > 0              THEN 'manual_force'
    WHEN (COALESCE(sm.MJ_REQ,0) - COALESCE(ar.SHIPPED_QTY,0))
         >= COALESCE(sm.MJ_REQ,0) * 0.5         THEN 'dc_redistribute'
    ELSE 'lift_cap'
  END                                                           AS FIX_ACTION,
  -- severity formula (exact)
  GREATEST(COALESCE(sm.MJ_REQ,0) - COALESCE(ar.SHIPPED_QTY,0), 0)
    * COALESCE(srn.STORE_PRIORITY, 0.5)
    * COALESCE(mp.MAJCAT_PRIORITY, 0.5)
    * POWER(0.95, DATEDIFF('day', s.RUN_DATE, CURRENT_DATE))
    * 1                                                         AS SEVERITY,
  OBJECT_CONSTRUCT(
    'mj_req',               sm.MJ_REQ,
    'shipped_qty',          COALESCE(ar.SHIPPED_QTY, 0),
    'alloc_qty_total',      COALESCE(ar.ALLOC_QTY_TOTAL, 0),
    'alloc_rows_ok',        COALESCE(ar.ALLOC_ROWS_OK, 0),
    'alloc_rows_skipped',   COALESCE(ar.ALLOC_ROWS_SKIPPED, 0),
    'alloc_rows_total',     COALESCE(ar.ALLOC_ROWS_TOTAL, 0),
    'elig_gen_art_count',   sm.ELIG_GEN_ART_COUNT,
    'total_gen_art_count',  sm.TOTAL_GEN_ART_COUNT,
    'st_rank',              sm.ST_RANK,
    'store_priority',       COALESCE(srn.STORE_PRIORITY, 0.5),
    'majcat_priority',      COALESCE(mp.MAJCAT_PRIORITY, 0.5),
    'recency_decay',        POWER(0.95, DATEDIFF('day', s.RUN_DATE, CURRENT_DATE)),
    'rule_weight',          1,
    'detected_pattern',     CASE
                              WHEN ar.SESSION_ID IS NULL          THEN 'NO_ALLOC_ROW'
                              WHEN ar.ALLOC_ROWS_OK = 0
                               AND ar.ALLOC_ROWS_SKIPPED > 0      THEN 'ALL_SKIPPED'
                              ELSE 'PARTIAL_UNDERFILL'
                            END
  )                                                             AS DETAIL_JSON
FROM store_majcat sm
JOIN sessions s              ON s.SESSION_ID = sm.SESSION_ID
LEFT JOIN alloc_rollup ar    ON ar.SESSION_ID = sm.SESSION_ID
                            AND ar.STORE      = sm.STORE
                            AND ar.MAJ_CAT    = sm.MAJ_CAT
LEFT JOIN store_rank_norm srn ON srn.SESSION_ID = sm.SESSION_ID
                             AND srn.STORE      = sm.STORE
LEFT JOIN majcat_priority mp  ON mp.MAJ_CAT     = sm.MAJ_CAT
WHERE sm.MJ_REQ > 0
  AND sm.HAS_ELIG_MSA = 1
  AND (
        ar.SESSION_ID IS NULL                                    -- no alloc row at all
     OR (ar.ALLOC_ROWS_OK = 0 AND ar.ALLOC_ROWS_SKIPPED > 0)     -- all SKIPPED
     OR COALESCE(ar.SHIPPED_QTY, 0) < sm.MJ_REQ                  -- underfill
      );

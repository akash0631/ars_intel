-- ============================================================================
-- Rule R3: ATTR_MIX_DRIFT
-- ----------------------------------------------------------------------------
-- WHAT:
--   For each session × majcat × attribute dimension (FAB, CLR, RNG_SEG, FIT,
--   M_VND_CD, M_YARN_02, WEAVE_2), compare the BASELINE contribution mix
--   (Master_CONT_<ATTR>.CONT_PCT, sourced via V_SILVER_LISTING which exposes
--   the per-attribute *_CONT columns) against the ACTUAL shipped mix derived
--   from V_SILVER_ALLOC × MASTER_PRODUCT attribute lookup.
--
--   Flag any (majcat, attr_dim, attr_val) where |actual_pct - baseline_pct|
--   exceeds 0.15 (15 percentage-point drift). One alert row per
--   (session, majcat, attr_dim) — keep the dimension's worst-drift value.
--
-- LOST_QTY MEANING:
--   The volumetric magnitude of the drift expressed as ship-units:
--     lost_qty = ABS(actual_pct - baseline_pct) * majcat_total_ship_qty
--   i.e. how many units shipped to the wrong attribute bucket vs. plan.
--
-- ROOT CAUSE INFERENCE (ALLOC_REASON is always NULL in source):
--   We infer drift drivers by inspecting which attribute over/under-shipped
--   relative to baseline. Common patterns: vendor mix skew (M_VND_CD),
--   color over-allocation (CLR), fabric drift (FAB), segment shift (RNG_SEG).
--
-- SEVERITY:
--   lost_qty * store_priority * majcat_priority * recency_decay * 0.7
--   - store_priority = NULL (alert is majcat-grain, not store-grain) -> 0.5
--   - majcat_priority = trailing-30d majcat ship share over total ship
--   - recency_decay  = POWER(0.95, DATEDIFF('day', RUN_DATE, CURRENT_DATE))
--
-- NOTES:
--   - Reads ONLY from V2RETAIL.ARS_GOLD.V_SILVER_* views (no BRONZE).
--   - R3 is a majcat-grain rule -> STORE / GEN_ART_NUMBER / VAR_ART are NULL.
--   - Idempotent: leading DELETE scopes to RULE_ID='R3' and the same
--     SESSION_ID universe being re-computed below.
-- ============================================================================

DELETE FROM V2RETAIL.ARS_GOLD.MART_ALERTS
WHERE RULE_ID = 'R3'
  AND SESSION_ID IN (
    SELECT SESSION_ID
    FROM V2RETAIL.ARS_GOLD.V_SILVER_SESSIONS
    WHERE STATUS = 'SUCCESS'
      AND STARTED_AT >= DATEADD('day', -7, CURRENT_DATE)
  );

INSERT INTO V2RETAIL.ARS_GOLD.MART_ALERTS (
  RULE_ID, SESSION_ID, RUN_DATE, STORE, MAJ_CAT, GEN_ART_NUMBER, VAR_ART,
  ATTR_DIM, ATTR_VAL, LOST_QTY, ROOT_CAUSE, FIX_ACTION, SEVERITY, DETAIL_JSON
)
WITH sessions_in_scope AS (
  SELECT
    SESSION_ID,
    CAST(STARTED_AT AS DATE) AS RUN_DATE
  FROM V2RETAIL.ARS_GOLD.V_SILVER_SESSIONS
  WHERE STATUS = 'SUCCESS'
    AND STARTED_AT >= DATEADD('day', -7, CURRENT_DATE)
),
-- ---- majcat ship-share priority over trailing 30d -------------------------
majcat_ship_30d AS (
  SELECT
    a.MAJ_CAT,
    SUM(a.SHIP_QTY) AS MJ_SHIP
  FROM V2RETAIL.ARS_GOLD.V_SILVER_ALLOC a
  JOIN V2RETAIL.ARS_GOLD.V_SILVER_SESSIONS s
    ON s.SESSION_ID = a.SESSION_ID
  WHERE s.STARTED_AT >= DATEADD('day', -30, CURRENT_DATE)
    AND a.SHIP_QTY > 0
    AND a.MAJ_CAT IS NOT NULL
  GROUP BY a.MAJ_CAT
),
total_ship_30d AS (
  SELECT SUM(MJ_SHIP) AS TOTAL_SHIP FROM majcat_ship_30d
),
majcat_priority AS (
  SELECT
    m.MAJ_CAT,
    COALESCE(m.MJ_SHIP / NULLIF(t.TOTAL_SHIP, 0), 0.5) AS MAJCAT_PRIORITY
  FROM majcat_ship_30d m
  CROSS JOIN total_ship_30d t
),
-- ---- one row per (session, gen_art) carrying every attr value -------------
-- V_SILVER_ALLOC already exposes all 8 attribute cols; no MASTER_PRODUCT join needed.
alloc_attr AS (
  SELECT
    a.SESSION_ID,
    a.MAJ_CAT,
    a.GEN_ART_NUMBER,
    a.FAB,
    a.CLR,
    a.RNG_SEG,
    a.FIT,
    a.M_VND_CD,
    a.M_YARN_02,
    a.WEAVE_2,
    a.SHIP_QTY
  FROM V2RETAIL.ARS_GOLD.V_SILVER_ALLOC a
  WHERE a.SHIP_QTY > 0
    AND a.SESSION_ID IN (SELECT SESSION_ID FROM sessions_in_scope)
),
-- ---- baseline contributions per attr exposed via V_SILVER_LISTING ---------
-- V_SILVER_LISTING exposes <ATTR>_CONT per (session, majcat, gen_art); the
-- attribute baseline is the same for all gen_arts inside a majcat, so we
-- average to get the planning CONT_PCT for the session.
baseline AS (
  SELECT
    SESSION_ID,
    MAJ_CAT,
    'FAB'        AS ATTR_DIM, FAB        AS ATTR_VAL, AVG(FAB_CONT)        AS BASELINE_PCT
  FROM V2RETAIL.ARS_GOLD.V_SILVER_LISTING
  WHERE SESSION_ID IN (SELECT SESSION_ID FROM sessions_in_scope)
    AND FAB IS NOT NULL
  GROUP BY SESSION_ID, MAJ_CAT, FAB
  UNION ALL
  SELECT SESSION_ID, MAJ_CAT, 'CLR', CLR, AVG(CLR_CONT)
  FROM V2RETAIL.ARS_GOLD.V_SILVER_LISTING
  WHERE SESSION_ID IN (SELECT SESSION_ID FROM sessions_in_scope) AND CLR IS NOT NULL
  GROUP BY SESSION_ID, MAJ_CAT, CLR
  UNION ALL
  SELECT SESSION_ID, MAJ_CAT, 'RNG_SEG', RNG_SEG, AVG(RNG_SEG_CONT)
  FROM V2RETAIL.ARS_GOLD.V_SILVER_LISTING
  WHERE SESSION_ID IN (SELECT SESSION_ID FROM sessions_in_scope) AND RNG_SEG IS NOT NULL
  GROUP BY SESSION_ID, MAJ_CAT, RNG_SEG
  UNION ALL
  SELECT SESSION_ID, MAJ_CAT, 'FIT', FIT, AVG(FIT_CONT)
  FROM V2RETAIL.ARS_GOLD.V_SILVER_LISTING
  WHERE SESSION_ID IN (SELECT SESSION_ID FROM sessions_in_scope) AND FIT IS NOT NULL
  GROUP BY SESSION_ID, MAJ_CAT, FIT
  UNION ALL
  SELECT SESSION_ID, MAJ_CAT, 'M_VND_CD', TO_VARCHAR(M_VND_CD), AVG(M_VND_CD_CONT)
  FROM V2RETAIL.ARS_GOLD.V_SILVER_LISTING
  WHERE SESSION_ID IN (SELECT SESSION_ID FROM sessions_in_scope) AND M_VND_CD IS NOT NULL
  GROUP BY SESSION_ID, MAJ_CAT, M_VND_CD
  UNION ALL
  SELECT SESSION_ID, MAJ_CAT, 'M_YARN_02', M_YARN_02, AVG(M_YARN_02_CONT)
  FROM V2RETAIL.ARS_GOLD.V_SILVER_LISTING
  WHERE SESSION_ID IN (SELECT SESSION_ID FROM sessions_in_scope) AND M_YARN_02 IS NOT NULL
  GROUP BY SESSION_ID, MAJ_CAT, M_YARN_02
  UNION ALL
  SELECT SESSION_ID, MAJ_CAT, 'WEAVE_2', WEAVE_2, AVG(WEAVE_2_CONT)
  FROM V2RETAIL.ARS_GOLD.V_SILVER_LISTING
  WHERE SESSION_ID IN (SELECT SESSION_ID FROM sessions_in_scope) AND WEAVE_2 IS NOT NULL
  GROUP BY SESSION_ID, MAJ_CAT, WEAVE_2
),
-- ---- actual ship mix per attr from V_SILVER_ALLOC × MASTER_PRODUCT --------
mj_ship_session AS (
  SELECT SESSION_ID, MAJ_CAT, SUM(SHIP_QTY) AS MJ_TOTAL_SHIP
  FROM alloc_attr
  GROUP BY SESSION_ID, MAJ_CAT
),
actual_long AS (
  SELECT a.SESSION_ID, a.MAJ_CAT, 'FAB' AS ATTR_DIM, a.FAB AS ATTR_VAL, SUM(a.SHIP_QTY) AS SHIP_QTY
    FROM alloc_attr a WHERE a.FAB IS NOT NULL GROUP BY a.SESSION_ID, a.MAJ_CAT, a.FAB
  UNION ALL
  SELECT SESSION_ID, MAJ_CAT, 'CLR', CLR, SUM(SHIP_QTY)
    FROM alloc_attr WHERE CLR IS NOT NULL GROUP BY SESSION_ID, MAJ_CAT, CLR
  UNION ALL
  SELECT SESSION_ID, MAJ_CAT, 'RNG_SEG', RNG_SEG, SUM(SHIP_QTY)
    FROM alloc_attr WHERE RNG_SEG IS NOT NULL GROUP BY SESSION_ID, MAJ_CAT, RNG_SEG
  UNION ALL
  SELECT SESSION_ID, MAJ_CAT, 'FIT', FIT, SUM(SHIP_QTY)
    FROM alloc_attr WHERE FIT IS NOT NULL GROUP BY SESSION_ID, MAJ_CAT, FIT
  UNION ALL
  SELECT SESSION_ID, MAJ_CAT, 'M_VND_CD', TO_VARCHAR(M_VND_CD), SUM(SHIP_QTY)
    FROM alloc_attr WHERE M_VND_CD IS NOT NULL GROUP BY SESSION_ID, MAJ_CAT, M_VND_CD
  UNION ALL
  SELECT SESSION_ID, MAJ_CAT, 'M_YARN_02', M_YARN_02, SUM(SHIP_QTY)
    FROM alloc_attr WHERE M_YARN_02 IS NOT NULL GROUP BY SESSION_ID, MAJ_CAT, M_YARN_02
  UNION ALL
  SELECT SESSION_ID, MAJ_CAT, 'WEAVE_2', WEAVE_2, SUM(SHIP_QTY)
    FROM alloc_attr WHERE WEAVE_2 IS NOT NULL GROUP BY SESSION_ID, MAJ_CAT, WEAVE_2
),
actual_pct AS (
  SELECT
    al.SESSION_ID, al.MAJ_CAT, al.ATTR_DIM, al.ATTR_VAL,
    al.SHIP_QTY,
    ms.MJ_TOTAL_SHIP,
    al.SHIP_QTY / NULLIF(ms.MJ_TOTAL_SHIP, 0) AS ACTUAL_PCT
  FROM actual_long al
  JOIN mj_ship_session ms
    ON ms.SESSION_ID = al.SESSION_ID
   AND ms.MAJ_CAT    = al.MAJ_CAT
),
-- ---- drift = |actual - baseline| per attr value ---------------------------
drift AS (
  SELECT
    COALESCE(a.SESSION_ID, b.SESSION_ID) AS SESSION_ID,
    COALESCE(a.MAJ_CAT,    b.MAJ_CAT)    AS MAJ_CAT,
    COALESCE(a.ATTR_DIM,   b.ATTR_DIM)   AS ATTR_DIM,
    COALESCE(a.ATTR_VAL,   b.ATTR_VAL)   AS ATTR_VAL,
    COALESCE(b.BASELINE_PCT, 0)          AS BASELINE_PCT,
    COALESCE(a.ACTUAL_PCT,   0)          AS ACTUAL_PCT,
    ABS(COALESCE(a.ACTUAL_PCT, 0) - COALESCE(b.BASELINE_PCT, 0)) AS DRIFT_ABS,
    COALESCE(a.ACTUAL_PCT, 0) - COALESCE(b.BASELINE_PCT, 0)      AS DRIFT_SIGNED,
    a.MJ_TOTAL_SHIP
  FROM actual_pct a
  FULL OUTER JOIN baseline b
    ON  b.SESSION_ID = a.SESSION_ID
    AND b.MAJ_CAT    = a.MAJ_CAT
    AND b.ATTR_DIM   = a.ATTR_DIM
    AND b.ATTR_VAL   = a.ATTR_VAL
),
-- ---- keep the worst-drift attr value per (session, majcat, attr_dim) ------
ranked AS (
  SELECT
    d.*,
    ROW_NUMBER() OVER (
      PARTITION BY SESSION_ID, MAJ_CAT, ATTR_DIM
      ORDER BY DRIFT_ABS DESC NULLS LAST
    ) AS RN
  FROM drift d
  WHERE DRIFT_ABS > 0.15
),
worst AS (
  SELECT
    r.SESSION_ID,
    r.MAJ_CAT,
    r.ATTR_DIM,
    r.ATTR_VAL,
    r.BASELINE_PCT,
    r.ACTUAL_PCT,
    r.DRIFT_ABS,
    r.DRIFT_SIGNED,
    COALESCE(r.MJ_TOTAL_SHIP, m.MJ_TOTAL_SHIP) AS MJ_TOTAL_SHIP,
    -- lost_qty = drift magnitude × total majcat ship
    r.DRIFT_ABS * COALESCE(r.MJ_TOTAL_SHIP, m.MJ_TOTAL_SHIP) AS LOST_QTY
  FROM ranked r
  LEFT JOIN mj_ship_session m
    ON m.SESSION_ID = r.SESSION_ID
   AND m.MAJ_CAT    = r.MAJ_CAT
  WHERE r.RN = 1
)
SELECT
  'R3'                                       AS RULE_ID,
  w.SESSION_ID                               AS SESSION_ID,
  s.RUN_DATE                                 AS RUN_DATE,
  CAST(NULL AS VARCHAR)                      AS STORE,
  w.MAJ_CAT                                  AS MAJ_CAT,
  CAST(NULL AS VARCHAR)                      AS GEN_ART_NUMBER,
  CAST(NULL AS VARCHAR)                      AS VAR_ART,
  w.ATTR_DIM                                 AS ATTR_DIM,
  w.ATTR_VAL                                 AS ATTR_VAL,
  COALESCE(w.LOST_QTY, 0)                    AS LOST_QTY,
  -- business-meaningful root cause based on drift direction + dimension
  CASE
    WHEN w.ATTR_DIM = 'M_VND_CD' AND w.DRIFT_SIGNED > 0 THEN
      'Vendor ' || w.ATTR_VAL || ' over-shipped vs plan (actual '
        || TO_VARCHAR(ROUND(w.ACTUAL_PCT*100,1)) || '% vs baseline '
        || TO_VARCHAR(ROUND(w.BASELINE_PCT*100,1)) || '%) - likely vendor-skew in MSA pool'
    WHEN w.ATTR_DIM = 'M_VND_CD' AND w.DRIFT_SIGNED < 0 THEN
      'Vendor ' || w.ATTR_VAL || ' under-shipped vs plan - DC stock-out or ELIG=NO_STOCK'
    WHEN w.ATTR_DIM = 'CLR' AND w.DRIFT_SIGNED > 0 THEN
      'Colour ' || w.ATTR_VAL || ' over-allocated (' || TO_VARCHAR(ROUND(w.DRIFT_ABS*100,1))
        || ' pts drift) - DC heavy on this colour'
    WHEN w.ATTR_DIM = 'CLR' AND w.DRIFT_SIGNED < 0 THEN
      'Colour ' || w.ATTR_VAL || ' under-allocated - DC stock gap or display blocked'
    WHEN w.ATTR_DIM = 'FAB' THEN
      'Fabric ' || w.ATTR_VAL || ' drift ' || TO_VARCHAR(ROUND(w.DRIFT_ABS*100,1))
        || ' pts - articles in this fabric over/under-represented in shipped pool'
    WHEN w.ATTR_DIM = 'RNG_SEG' THEN
      'Range-segment ' || w.ATTR_VAL || ' mix drifted '
        || TO_VARCHAR(ROUND(w.DRIFT_ABS*100,1)) || ' pts - segment plan vs ship mismatch'
    WHEN w.ATTR_DIM = 'FIT' THEN
      'Fit ' || w.ATTR_VAL || ' drifted ' || TO_VARCHAR(ROUND(w.DRIFT_ABS*100,1))
        || ' pts - fit pool not honoured by allocator'
    WHEN w.ATTR_DIM = 'M_YARN_02' THEN
      'Yarn ' || w.ATTR_VAL || ' drifted ' || TO_VARCHAR(ROUND(w.DRIFT_ABS*100,1))
        || ' pts vs CONT_M_YARN_02 baseline'
    WHEN w.ATTR_DIM = 'WEAVE_2' THEN
      'Weave ' || w.ATTR_VAL || ' drifted ' || TO_VARCHAR(ROUND(w.DRIFT_ABS*100,1))
        || ' pts vs CONT_WEAVE_2 baseline'
    ELSE
      w.ATTR_DIM || ' = ' || COALESCE(w.ATTR_VAL,'<null>') || ' drifted '
        || TO_VARCHAR(ROUND(w.DRIFT_ABS*100,1)) || ' pts vs baseline'
  END                                        AS ROOT_CAUSE,
  -- fix action enum
  CASE
    WHEN w.ATTR_DIM = 'M_VND_CD' AND w.DRIFT_SIGNED < 0 THEN 'dc_redistribute'
    WHEN w.ATTR_DIM = 'CLR'      AND w.DRIFT_SIGNED < 0 THEN 'dc_redistribute'
    WHEN w.DRIFT_ABS > 0.30                              THEN 'escalate'
    WHEN w.ATTR_DIM IN ('FAB','RNG_SEG','FIT')           THEN 'manual_force'
    ELSE 'investigate'
  END                                        AS FIX_ACTION,
  -- severity = lost_qty * store_priority(0.5) * majcat_priority * decay * 0.7
  COALESCE(w.LOST_QTY, 0)
    * 0.5
    * COALESCE(mp.MAJCAT_PRIORITY, 0.5)
    * POWER(0.95, DATEDIFF('day', s.RUN_DATE, CURRENT_DATE))
    * 0.7                                    AS SEVERITY,
  OBJECT_CONSTRUCT(
    'attr_dim',        w.ATTR_DIM,
    'attr_val',        w.ATTR_VAL,
    'baseline_pct',    ROUND(w.BASELINE_PCT, 4),
    'actual_pct',      ROUND(w.ACTUAL_PCT,   4),
    'drift_abs',       ROUND(w.DRIFT_ABS,    4),
    'drift_signed',    ROUND(w.DRIFT_SIGNED, 4),
    'drift_threshold', 0.15,
    'mj_total_ship',   w.MJ_TOTAL_SHIP,
    'lost_qty',        ROUND(COALESCE(w.LOST_QTY,0), 2),
    'majcat_priority', ROUND(COALESCE(mp.MAJCAT_PRIORITY,0.5), 4),
    'store_priority',  0.5,
    'recency_decay',   POWER(0.95, DATEDIFF('day', s.RUN_DATE, CURRENT_DATE)),
    'rule_weight',     0.7
  )                                          AS DETAIL_JSON
FROM worst w
JOIN sessions_in_scope s
  ON s.SESSION_ID = w.SESSION_ID
LEFT JOIN majcat_priority mp
  ON mp.MAJ_CAT = w.MAJ_CAT
WHERE COALESCE(w.LOST_QTY, 0) > 0;

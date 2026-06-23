-- =====================================================================
-- Rule R10: STORE_STARVATION
-- ---------------------------------------------------------------------
-- Detects stores that are being systematically under-served by the ARS
-- allocation engine. For each (store, run_date) we compute a daily
-- fill ratio = SUM(SHIP_QTY) / SUM(MJ_REQ) across all majcats. A store
-- is flagged when its daily fill% stays BELOW 0.50 for >= 3 CONSECUTIVE
-- run_dates within the observed silver window.
--
-- lost_qty meaning:
--   Sum of (MJ_REQ - SHIP_QTY) across all qualifying starvation days
--   for the store. Represents demand that the engine acknowledged
--   (MJ_REQ > 0) but failed to fulfil. Floored at 0 per day.
--
-- Severity formula (rule weight = 1):
--   lost_qty
--     * store_priority      (normalized ST_RANK from V_SILVER_LISTING, fallback 0.5)
--     * majcat_priority     (majcat ship contribution % over trailing 30d, fallback 0.5)
--     * recency_decay       (POWER(0.95, DATEDIFF('day', RUN_DATE, CURRENT_DATE)))
--     * 1                   (rule weight)
--
-- Notes / gotchas:
--   * ALLOC_REASON is always NULL in source - we infer the root cause
--     from the joined silver views.
--   * We read ONLY from V2RETAIL.ARS_GOLD silver views, never bronze.
--   * Store-level rollup: MAJ_CAT / GEN_ART_NUMBER / VAR_ART / ATTR_*
--     are NULL since R10 is a whole-store signal.
--   * Idempotent: pre-delete any existing R10 rows for the in-scope
--     sessions before re-insert.
-- =====================================================================

DELETE FROM V2RETAIL.ARS_GOLD.MART_ALERTS
WHERE RULE_ID = 'R10'
  AND SESSION_ID IN (
    SELECT DISTINCT s.SESSION_ID
    FROM V2RETAIL.ARS_GOLD.V_SILVER_SESSIONS s
    WHERE s.STATUS = 'SUCCESS'
      AND s.STARTED_AT >= DATEADD('day', -30, CURRENT_DATE)
  );

INSERT INTO V2RETAIL.ARS_GOLD.MART_ALERTS (
    RULE_ID, SESSION_ID, RUN_DATE, STORE, MAJ_CAT, GEN_ART_NUMBER, VAR_ART,
    ATTR_DIM, ATTR_VAL, LOST_QTY, ROOT_CAUSE, FIX_ACTION, SEVERITY, DETAIL_JSON
)
WITH sess AS (
    -- In-scope sessions: last 30d SUCCESS runs from silver
    SELECT
        s.SESSION_ID,
        CAST(s.STARTED_AT AS DATE) AS RUN_DATE
    FROM V2RETAIL.ARS_GOLD.V_SILVER_SESSIONS s
    WHERE s.STATUS = 'SUCCESS'
      AND s.STARTED_AT >= DATEADD('day', -30, CURRENT_DATE)
),
-- Per-store-per-day requirement (MJ_REQ at store level via listing)
store_day_req AS (
    SELECT
        sess.SESSION_ID,
        sess.RUN_DATE,
        l.WERKS                              AS STORE,
        SUM(COALESCE(l.MJ_REQ, 0))           AS TOTAL_REQ
    FROM sess
    JOIN V2RETAIL.ARS_GOLD.V_SILVER_LISTING l
      ON l.SESSION_ID = sess.SESSION_ID
    WHERE l.WERKS IS NOT NULL
    GROUP BY sess.SESSION_ID, sess.RUN_DATE, l.WERKS
),
-- Per-store-per-day shipped quantity
store_day_ship AS (
    SELECT
        sess.SESSION_ID,
        sess.RUN_DATE,
        a.WERKS                              AS STORE,
        SUM(COALESCE(a.SHIP_QTY, 0))         AS TOTAL_SHIP,
        SUM(COALESCE(a.HOLD_QTY, 0))         AS TOTAL_HOLD
    FROM sess
    JOIN V2RETAIL.ARS_GOLD.V_SILVER_ALLOC a
      ON a.SESSION_ID = sess.SESSION_ID
    WHERE a.WERKS IS NOT NULL
    GROUP BY sess.SESSION_ID, sess.RUN_DATE, a.WERKS
),
-- Combined daily fill metric
store_day AS (
    SELECT
        COALESCE(r.SESSION_ID, s.SESSION_ID) AS SESSION_ID,
        COALESCE(r.RUN_DATE,   s.RUN_DATE)   AS RUN_DATE,
        COALESCE(r.STORE,      s.STORE)      AS STORE,
        COALESCE(r.TOTAL_REQ,  0)            AS TOTAL_REQ,
        COALESCE(s.TOTAL_SHIP, 0)            AS TOTAL_SHIP,
        COALESCE(s.TOTAL_HOLD, 0)            AS TOTAL_HOLD,
        CASE
            WHEN COALESCE(r.TOTAL_REQ, 0) > 0
              THEN COALESCE(s.TOTAL_SHIP, 0) / r.TOTAL_REQ
            ELSE NULL
        END                                   AS FILL_PCT,
        GREATEST(COALESCE(r.TOTAL_REQ, 0) - COALESCE(s.TOTAL_SHIP, 0), 0) AS DAY_LOST_QTY
    FROM store_day_req r
    FULL OUTER JOIN store_day_ship s
      ON r.SESSION_ID = s.SESSION_ID
     AND r.STORE      = s.STORE
),
-- Flag starvation days (fill% < 0.50 and there was real demand)
flagged AS (
    SELECT
        sd.*,
        CASE
            WHEN sd.TOTAL_REQ > 0 AND sd.FILL_PCT < 0.50 THEN 1
            ELSE 0
        END AS IS_STARVED
    FROM store_day sd
),
-- Compute consecutive-day run lengths per store using the classic
-- "row_number() difference" islands-and-gaps trick on RUN_DATE.
ranked AS (
    SELECT
        f.*,
        ROW_NUMBER() OVER (PARTITION BY f.STORE             ORDER BY f.RUN_DATE) AS RN_ALL,
        ROW_NUMBER() OVER (PARTITION BY f.STORE, f.IS_STARVED ORDER BY f.RUN_DATE) AS RN_GRP
    FROM flagged f
),
runs AS (
    SELECT
        STORE,
        IS_STARVED,
        DATEADD('day', -RN_GRP, RUN_DATE) AS RUN_GROUP_KEY,
        MIN(RUN_DATE) AS RUN_START,
        MAX(RUN_DATE) AS RUN_END,
        COUNT(*)      AS DAYS_BELOW,
        AVG(FILL_PCT) AS AVG_FILL_PCT,
        SUM(DAY_LOST_QTY) AS TOTAL_LOST_QTY,
        SUM(TOTAL_REQ)    AS TOTAL_REQ_IN_RUN,
        SUM(TOTAL_SHIP)   AS TOTAL_SHIP_IN_RUN,
        SUM(TOTAL_HOLD)   AS TOTAL_HOLD_IN_RUN,
        -- Carry the latest session for this store-run for attribution
        MAX(SESSION_ID)   AS LATEST_SESSION_ID
    FROM ranked
    WHERE IS_STARVED = 1
    GROUP BY STORE, IS_STARVED, DATEADD('day', -RN_GRP, RUN_DATE)
),
starvation_runs AS (
    SELECT *
    FROM runs
    WHERE DAYS_BELOW >= 3
),
-- ---- priority signals ----
-- Store priority: normalized ST_RANK (lower rank = higher priority -> higher weight)
store_rank AS (
    SELECT
        l.WERKS AS STORE,
        AVG(NULLIF(l.ST_RANK, 0)) AS AVG_ST_RANK
    FROM V2RETAIL.ARS_GOLD.V_SILVER_LISTING l
    WHERE l.WERKS IS NOT NULL
    GROUP BY l.WERKS
),
rank_bounds AS (
    SELECT
        MIN(AVG_ST_RANK) AS MIN_R,
        MAX(AVG_ST_RANK) AS MAX_R
    FROM store_rank
    WHERE AVG_ST_RANK IS NOT NULL
),
store_priority AS (
    SELECT
        sr.STORE,
        CASE
            WHEN sr.AVG_ST_RANK IS NULL OR rb.MAX_R IS NULL OR rb.MAX_R = rb.MIN_R THEN 0.5
            ELSE 1.0 - ((sr.AVG_ST_RANK - rb.MIN_R) / NULLIF(rb.MAX_R - rb.MIN_R, 0))
        END AS STORE_PRIORITY
    FROM store_rank sr
    CROSS JOIN rank_bounds rb
),
-- Majcat priority: trailing-30d ship contribution % from V_SILVER_ALLOC.
-- Since allocation rows don't carry MAJ_CAT directly, join through silver
-- listing to map (SESSION_ID, GEN_ART_NUMBER) -> MAJ_CAT.
maj_ship_30d AS (
    SELECT
        gm.MAJ_CAT,
        SUM(COALESCE(a.SHIP_QTY, 0)) AS MAJ_SHIP
    FROM V2RETAIL.ARS_GOLD.V_SILVER_ALLOC a
    JOIN V2RETAIL.ARS_GOLD.V_SILVER_SESSIONS s
      ON s.SESSION_ID = a.SESSION_ID
    JOIN (
        SELECT DISTINCT SESSION_ID, GEN_ART_NUMBER, MAJ_CAT
        FROM V2RETAIL.ARS_GOLD.V_SILVER_LISTING
        WHERE MAJ_CAT IS NOT NULL
    ) gm
      ON gm.SESSION_ID     = a.SESSION_ID
     AND gm.GEN_ART_NUMBER = a.GEN_ART_NUMBER
    WHERE s.STARTED_AT >= DATEADD('day', -30, CURRENT_DATE)
      AND s.STATUS = 'SUCCESS'
    GROUP BY gm.MAJ_CAT
),
maj_total AS (
    SELECT SUM(MAJ_SHIP) AS GRAND_SHIP FROM maj_ship_30d
),
maj_priority AS (
    SELECT
        m.MAJ_CAT,
        CASE
            WHEN mt.GRAND_SHIP IS NULL OR mt.GRAND_SHIP = 0 THEN 0.5
            ELSE m.MAJ_SHIP / mt.GRAND_SHIP
        END AS MAJCAT_PRIORITY
    FROM maj_ship_30d m
    CROSS JOIN maj_total mt
),
-- Average majcat priority for the store across the run window:
-- weight by MJ_REQ exposure per majcat in that store.
store_maj_priority AS (
    SELECT
        l.WERKS AS STORE,
        SUM(COALESCE(mp.MAJCAT_PRIORITY, 0.5) * COALESCE(l.MJ_REQ, 0))
            / NULLIF(SUM(COALESCE(l.MJ_REQ, 0)), 0) AS STORE_MAJCAT_PRIORITY
    FROM V2RETAIL.ARS_GOLD.V_SILVER_LISTING l
    LEFT JOIN maj_priority mp ON mp.MAJ_CAT = l.MAJ_CAT
    WHERE l.WERKS IS NOT NULL
    GROUP BY l.WERKS
)
SELECT
    'R10'                                                        AS RULE_ID,
    sr.LATEST_SESSION_ID                                         AS SESSION_ID,
    sr.RUN_END                                                   AS RUN_DATE,
    sr.STORE                                                     AS STORE,
    CAST(NULL AS STRING)                                         AS MAJ_CAT,
    CAST(NULL AS STRING)                                         AS GEN_ART_NUMBER,
    CAST(NULL AS STRING)                                         AS VAR_ART,
    CAST(NULL AS STRING)                                         AS ATTR_DIM,
    CAST(NULL AS STRING)                                         AS ATTR_VAL,
    sr.TOTAL_LOST_QTY                                            AS LOST_QTY,
    'Store fill% < 50% for ' || sr.DAYS_BELOW
        || ' consecutive run-days (' || TO_VARCHAR(sr.RUN_START)
        || ' to ' || TO_VARCHAR(sr.RUN_END)
        || '); engine acknowledged demand but did not ship.'     AS ROOT_CAUSE,
    'rerank_store'                                               AS FIX_ACTION,
    (
        sr.TOTAL_LOST_QTY
        * COALESCE(sp.STORE_PRIORITY,        0.5)
        * COALESCE(smp.STORE_MAJCAT_PRIORITY, 0.5)
        * POWER(0.95, DATEDIFF('day', sr.RUN_END, CURRENT_DATE))
        * 1
    )                                                            AS SEVERITY,
    OBJECT_CONSTRUCT(
        'rule',               'R10_STORE_STARVATION',
        'store',              sr.STORE,
        'run_start',          sr.RUN_START,
        'run_end',            sr.RUN_END,
        'days_below',         sr.DAYS_BELOW,
        'threshold_fill_pct', 0.50,
        'avg_fill_pct',       sr.AVG_FILL_PCT,
        'total_req',          sr.TOTAL_REQ_IN_RUN,
        'total_ship',         sr.TOTAL_SHIP_IN_RUN,
        'total_hold',         sr.TOTAL_HOLD_IN_RUN,
        'total_lost_qty',     sr.TOTAL_LOST_QTY,
        'store_priority',     COALESCE(sp.STORE_PRIORITY,        0.5),
        'majcat_priority',    COALESCE(smp.STORE_MAJCAT_PRIORITY, 0.5),
        'recency_decay',      POWER(0.95, DATEDIFF('day', sr.RUN_END, CURRENT_DATE)),
        'rule_weight',        1,
        'latest_session_id',  sr.LATEST_SESSION_ID,
        'inferred',           TRUE,
        'note',               'ALLOC_REASON is NULL in source; root cause inferred from silver joins.'
    )                                                            AS DETAIL_JSON
FROM starvation_runs        sr
LEFT JOIN store_priority    sp  ON sp.STORE  = sr.STORE
LEFT JOIN store_maj_priority smp ON smp.STORE = sr.STORE
WHERE sr.TOTAL_LOST_QTY > 0;

-- ============================================================================
-- Rule R9: MAJCAT_REGRESSION
-- ----------------------------------------------------------------------------
-- Detects MAJ_CAT-level allocation regressions across consecutive runs.
-- A regression fires when a MAJ_CAT was STATUS=DONE in a prior session but
-- transitions to STATUS=FAILED in the current session (with ERROR_MSG context).
-- Also factors in the 7d MAJ_CAT success-rate trend: a falling success rate
-- on the same MAJ_CAT amplifies the signal (treated as supporting evidence
-- in DETAIL_JSON; the alert itself fires on the DONE->FAILED transition).
--
-- lost_qty meaning:
--   Approx ship qty foregone by the regression — the prior successful run's
--   SHIP_QTY for that MAJ_CAT (from ARS_ALLOC_MAJCAT_QUEUE, exposed via
--   V_SILVER_SESSIONS / V_SILVER_ALLOC trailing aggregation). If unavailable,
--   falls back to current-session expected ship derived from V_SILVER_ALLOC
--   (sum of SHIP_QTY+HOLD_QTY for that MAJ_CAT in the failed session).
--
-- Notes:
--   * Reads ONLY from V2RETAIL.ARS_GOLD silver views.
--   * ALLOC_REASON is NULL in source — root cause is INFERRED from
--     ARS_ALLOC_MAJCAT_QUEUE.ERROR_MSG (surfaced via V_SILVER_SESSIONS).
--   * Idempotent on (RULE_ID='R9', SESSION_ID in scope).
--   * Severity formula:
--       severity = lost_qty
--                * store_priority   -- NULL at MAJ_CAT level → 0.5 fallback
--                * majcat_priority  -- MAJ_CAT 30d ship contribution %
--                * recency_decay    -- POWER(0.95, days_since_run)
--                * 1.2              -- rule weight R9
-- ============================================================================

-- Idempotent purge for current detector scope (last 7 days of sessions)
DELETE FROM V2RETAIL.ARS_GOLD.MART_ALERTS
WHERE RULE_ID = 'R9'
  AND SESSION_ID IN (
    SELECT DISTINCT s.SESSION_ID
    FROM V2RETAIL.ARS_GOLD.V_SILVER_SESSIONS s
    WHERE s.STARTED_AT >= DATEADD('day', -7, CURRENT_DATE)
  );

INSERT INTO V2RETAIL.ARS_GOLD.MART_ALERTS (
    RULE_ID, SESSION_ID, RUN_DATE, STORE, MAJ_CAT, GEN_ART_NUMBER, VAR_ART,
    ATTR_DIM, ATTR_VAL, LOST_QTY, ROOT_CAUSE, FIX_ACTION, SEVERITY, DETAIL_JSON
)
WITH sess AS (
    -- All sessions in detection window with their majcat-queue rollup.
    -- V_SILVER_SESSIONS exposes ARS_LISTING_SESSIONS joined to
    -- ARS_ALLOC_MAJCAT_QUEUE (one row per session x maj_cat).
    SELECT
        s.SESSION_ID,
        CAST(s.STARTED_AT AS DATE)        AS RUN_DATE,
        s.STARTED_AT,
        s.MAJ_CAT,
        s.MAJCAT_STATUS,                  -- DONE | FAILED | PENDING | RUNNING
        s.MAJCAT_ERROR_MSG,
        s.MAJCAT_SHIP_QTY,
        s.MAJCAT_HOLD_QTY,
        s.MAJCAT_ROWS_AFFECTED,
        s.MAJCAT_ATTEMPTS,
        s.MAJCAT_DURATION_SEC,
        s.ALLOCATION_MODE
    FROM V2RETAIL.ARS_GOLD.V_SILVER_SESSION_MAJCAT s
    WHERE s.STARTED_AT >= DATEADD('day', -7, CURRENT_DATE)
      AND s.MAJ_CAT IS NOT NULL
),
prev AS (
    -- For each (MAJ_CAT, session) find the immediately prior session's
    -- status + ship qty for the same MAJ_CAT.
    SELECT
        c.SESSION_ID,
        c.RUN_DATE,
        c.STARTED_AT,
        c.MAJ_CAT,
        c.MAJCAT_STATUS                AS CUR_STATUS,
        c.MAJCAT_ERROR_MSG             AS CUR_ERROR_MSG,
        c.MAJCAT_SHIP_QTY              AS CUR_SHIP_QTY,
        c.MAJCAT_HOLD_QTY              AS CUR_HOLD_QTY,
        c.MAJCAT_ROWS_AFFECTED         AS CUR_ROWS,
        c.MAJCAT_ATTEMPTS              AS CUR_ATTEMPTS,
        c.MAJCAT_DURATION_SEC          AS CUR_DURATION_SEC,
        c.ALLOCATION_MODE,
        LAG(c.MAJCAT_STATUS)   OVER (PARTITION BY c.MAJ_CAT ORDER BY c.STARTED_AT) AS PREV_STATUS,
        LAG(c.SESSION_ID)      OVER (PARTITION BY c.MAJ_CAT ORDER BY c.STARTED_AT) AS PREV_SESSION_ID,
        LAG(c.MAJCAT_SHIP_QTY) OVER (PARTITION BY c.MAJ_CAT ORDER BY c.STARTED_AT) AS PREV_SHIP_QTY,
        LAG(c.STARTED_AT)      OVER (PARTITION BY c.MAJ_CAT ORDER BY c.STARTED_AT) AS PREV_STARTED_AT
    FROM sess c
),
regressions AS (
    -- Core trigger: DONE -> FAILED transition on the same MAJ_CAT.
    SELECT *
    FROM prev
    WHERE CUR_STATUS  = 'FAILED'
      AND PREV_STATUS = 'DONE'
),
-- 7d success-rate trend per MAJ_CAT (supporting evidence in DETAIL_JSON).
trend_7d AS (
    SELECT
        MAJ_CAT,
        COUNT(*)                                                       AS RUNS_7D,
        SUM(CASE WHEN MAJCAT_STATUS = 'DONE' THEN 1 ELSE 0 END)         AS DONE_7D,
        SUM(CASE WHEN MAJCAT_STATUS = 'FAILED' THEN 1 ELSE 0 END)       AS FAILED_7D,
        DIV0(
            SUM(CASE WHEN MAJCAT_STATUS = 'DONE' THEN 1 ELSE 0 END) * 1.0,
            COUNT(*)
        )                                                              AS SUCCESS_RATE_7D
    FROM sess
    GROUP BY MAJ_CAT
),
-- MAJ_CAT priority = ship contribution % over trailing 30d (inline from V_SILVER_ALLOC).
majcat_30d AS (
    SELECT
        a.MAJ_CAT,
        SUM(COALESCE(a.SHIP_QTY, 0))                                   AS MJ_SHIP_30D
    FROM V2RETAIL.ARS_GOLD.V_SILVER_ALLOC a
    WHERE a.RUN_DATE >= DATEADD('day', -30, CURRENT_DATE)
      AND a.MAJ_CAT IS NOT NULL
    GROUP BY a.MAJ_CAT
),
majcat_30d_total AS (
    SELECT SUM(MJ_SHIP_30D) AS TOT_SHIP_30D FROM majcat_30d
),
majcat_priority AS (
    SELECT
        m.MAJ_CAT,
        COALESCE(
            DIV0(m.MJ_SHIP_30D * 1.0, t.TOT_SHIP_30D),
            0.5
        ) AS MJ_PRIORITY
    FROM majcat_30d m
    CROSS JOIN majcat_30d_total t
),
-- Current-session fallback ship (sum of SHIP_QTY + HOLD_QTY in failed session for that MAJ_CAT).
cur_alloc_rollup AS (
    SELECT
        a.SESSION_ID,
        a.MAJ_CAT,
        SUM(COALESCE(a.SHIP_QTY, 0) + COALESCE(a.HOLD_QTY, 0)) AS CUR_EXPECTED_SHIP
    FROM V2RETAIL.ARS_GOLD.V_SILVER_ALLOC a
    WHERE a.RUN_DATE >= DATEADD('day', -7, CURRENT_DATE)
    GROUP BY a.SESSION_ID, a.MAJ_CAT
)
SELECT
    'R9'                              AS RULE_ID,
    r.SESSION_ID                      AS SESSION_ID,
    r.RUN_DATE                        AS RUN_DATE,
    NULL                              AS STORE,            -- MAJ_CAT-level alert; not store-scoped
    r.MAJ_CAT                         AS MAJ_CAT,
    NULL                              AS GEN_ART_NUMBER,
    NULL                              AS VAR_ART,
    'MAJ_CAT'                         AS ATTR_DIM,
    r.MAJ_CAT                         AS ATTR_VAL,
    -- LOST_QTY: prefer prior successful run's ship qty; else current-session expected ship.
    COALESCE(r.PREV_SHIP_QTY, c.CUR_EXPECTED_SHIP, 0) AS LOST_QTY,
    -- ROOT_CAUSE: business-meaningful string inferred from ERROR_MSG + trend.
    CASE
        WHEN r.CUR_ERROR_MSG ILIKE '%timeout%' OR r.CUR_ERROR_MSG ILIKE '%timed out%'
            THEN 'majcat_regression_timeout: ' || r.MAJ_CAT
              || ' DONE -> FAILED (worker timeout after ' || COALESCE(r.CUR_DURATION_SEC, 0) || 's)'
        WHEN r.CUR_ERROR_MSG ILIKE '%deadlock%'
            THEN 'majcat_regression_deadlock: ' || r.MAJ_CAT || ' DONE -> FAILED (SQL deadlock during alloc)'
        WHEN r.CUR_ERROR_MSG ILIKE '%divide by zero%' OR r.CUR_ERROR_MSG ILIKE '%division by zero%'
            THEN 'majcat_regression_calc_error: ' || r.MAJ_CAT || ' DONE -> FAILED (division-by-zero in alloc math)'
        WHEN r.CUR_ERROR_MSG ILIKE '%null%' OR r.CUR_ERROR_MSG ILIKE '%missing%'
            THEN 'majcat_regression_data_gap: ' || r.MAJ_CAT || ' DONE -> FAILED (NULL/missing input)'
        WHEN r.CUR_ERROR_MSG ILIKE '%lock%' OR r.CUR_ERROR_MSG ILIKE '%blocked%'
            THEN 'majcat_regression_contention: ' || r.MAJ_CAT || ' DONE -> FAILED (resource contention)'
        WHEN COALESCE(r.CUR_ATTEMPTS, 1) >= 3
            THEN 'majcat_regression_persistent: ' || r.MAJ_CAT
              || ' DONE -> FAILED after ' || r.CUR_ATTEMPTS || ' attempts'
        WHEN t.SUCCESS_RATE_7D < 0.5
            THEN 'majcat_regression_trend: ' || r.MAJ_CAT
              || ' DONE -> FAILED (7d success rate ' || ROUND(t.SUCCESS_RATE_7D * 100, 0) || '%, deteriorating)'
        WHEN r.CUR_ERROR_MSG IS NOT NULL
            THEN 'majcat_regression: ' || r.MAJ_CAT || ' DONE -> FAILED (' || LEFT(r.CUR_ERROR_MSG, 120) || ')'
        ELSE 'majcat_regression: ' || r.MAJ_CAT || ' DONE -> FAILED (no error_msg captured)'
    END                               AS ROOT_CAUSE,
    -- FIX_ACTION enum routing.
    CASE
        WHEN r.CUR_ERROR_MSG ILIKE '%timeout%' OR r.CUR_ERROR_MSG ILIKE '%deadlock%'
             OR COALESCE(r.CUR_ATTEMPTS, 1) >= 3                            THEN 'escalate'
        WHEN r.CUR_ERROR_MSG ILIKE '%divide by zero%'
             OR r.CUR_ERROR_MSG ILIKE '%null%'
             OR r.CUR_ERROR_MSG ILIKE '%missing%'                           THEN 'manual_force'
        WHEN t.SUCCESS_RATE_7D < 0.5                                        THEN 'escalate'
        ELSE 'investigate'
    END                               AS FIX_ACTION,
    -- Severity (exact formula).
    COALESCE(r.PREV_SHIP_QTY, c.CUR_EXPECTED_SHIP, 0)
        * 0.5                                                        -- store_priority fallback (MAJ_CAT-level, no store)
        * COALESCE(mp.MJ_PRIORITY, 0.5)                              -- majcat_priority
        * POWER(0.95, DATEDIFF('day', r.RUN_DATE, CURRENT_DATE))     -- recency_decay
        * 1.2                                                        -- R9 rule weight
                                       AS SEVERITY,
    OBJECT_CONSTRUCT(
        'rule',                'R9',
        'rule_name',           'MAJCAT_REGRESSION',
        'maj_cat',             r.MAJ_CAT,
        'cur_session_id',      r.SESSION_ID,
        'cur_status',          r.CUR_STATUS,
        'cur_error_msg',       r.CUR_ERROR_MSG,
        'cur_ship_qty',        r.CUR_SHIP_QTY,
        'cur_hold_qty',        r.CUR_HOLD_QTY,
        'cur_rows_affected',   r.CUR_ROWS,
        'cur_attempts',        r.CUR_ATTEMPTS,
        'cur_duration_sec',    r.CUR_DURATION_SEC,
        'cur_expected_ship',   c.CUR_EXPECTED_SHIP,
        'prev_session_id',     r.PREV_SESSION_ID,
        'prev_status',         r.PREV_STATUS,
        'prev_ship_qty',       r.PREV_SHIP_QTY,
        'prev_started_at',     r.PREV_STARTED_AT,
        'transition',          'DONE->FAILED',
        'trend_7d_runs',       t.RUNS_7D,
        'trend_7d_done',       t.DONE_7D,
        'trend_7d_failed',     t.FAILED_7D,
        'trend_7d_success_rate', t.SUCCESS_RATE_7D,
        'majcat_priority_30d', COALESCE(mp.MJ_PRIORITY, 0.5),
        'store_priority',      0.5,
        'recency_decay',       POWER(0.95, DATEDIFF('day', r.RUN_DATE, CURRENT_DATE)),
        'rule_weight',         1.2,
        'allocation_mode',     r.ALLOCATION_MODE,
        'alloc_reason_inferred', TRUE,
        'inference_source',    'ARS_ALLOC_MAJCAT_QUEUE.ERROR_MSG + LAG(STATUS) by MAJ_CAT'
    )                                  AS DETAIL_JSON
FROM regressions r
LEFT JOIN trend_7d         t  ON t.MAJ_CAT  = r.MAJ_CAT
LEFT JOIN majcat_priority  mp ON mp.MAJ_CAT = r.MAJ_CAT
LEFT JOIN cur_alloc_rollup c  ON c.SESSION_ID = r.SESSION_ID
                              AND c.MAJ_CAT    = r.MAJ_CAT
;

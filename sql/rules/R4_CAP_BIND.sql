-- =============================================================================
-- Rule R4: CAP_BIND
-- -----------------------------------------------------------------------------
-- Detects which grid-level contribution cap (CONT% * MJ_MBQ) is the binding
-- constraint that clips an article's requirement during ARS listing/allocation.
--
-- Logic:
--   For each row in V_SILVER_LISTING (mirror of ARS_LISTING_HISTORY), a "cap
--   binds" when:
--       <ATTR>_REQ > <ATTR>_CONT * MJ_MBQ
--   evaluated across the 8 hierarchical grid attributes:
--       MERGE_RNG_SEG, RNG_SEG, M_YARN_02, WEAVE_2, FAB, CLR, M_VND_CD, FIT
--   The most-frequent binding cap per (session, store, maj_cat) wins. We then
--   sum the clipped_qty (= REQ - CAP) across the offending articles. ALLOC
--   facts (V_SILVER_ALLOC) supply the realized SHIP/HOLD shortfall so we can
--   measure true lost_qty as the unfulfilled portion vs MJ_REQ.
--
-- lost_qty meaning:
--   Sum of (per-attribute REQ - per-attribute CONT*MBQ) clipped to >=0, across
--   the articles in the (session, store, maj_cat) bucket whose binding cap
--   matches the modal attribute. Approximates the units the cap shaved off.
--
-- Severity formula:
--   severity = lost_qty
--            * store_priority   (normalized ST_RANK; fallback 0.5)
--            * majcat_priority  (majcat ship % over trailing 30d; fallback 0.5)
--            * recency_decay    (POWER(0.95, age_days))
--            * 0.9              (rule weight)
--
-- Source: ONLY V2RETAIL.ARS_GOLD.V_SILVER_* views (no BRONZE direct reads).
-- Target: V2RETAIL.ARS_GOLD.MART_ALERTS
-- Notes:
--   - ALLOC_REASON is always NULL in source; binding cap is INFERRED from
--     LISTING_HISTORY arithmetic (REQ vs CONT*MBQ).
--   - Idempotent: deletes any prior R4 rows for the in-scope sessions first.
--   - FIX_ACTION enum: lift_cap | dc_redistribute | rerank_store |
--                      manual_force | escalate | investigate
-- =============================================================================

DELETE FROM V2RETAIL.ARS_GOLD.MART_ALERTS
WHERE RULE_ID = 'R4'
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
WITH sess AS (
    SELECT
        SESSION_ID,
        CAST(STARTED_AT AS DATE) AS RUN_DATE
    FROM V2RETAIL.ARS_GOLD.V_SILVER_SESSIONS
    WHERE STATUS = 'SUCCESS'
      AND STARTED_AT >= DATEADD('day', -7, CURRENT_DATE)
),
-- Unpivot the 8 grid caps and detect per-row binding.
binds AS (
    SELECT
        l.SESSION_ID,
        l.WERKS,
        l.MAJ_CAT,
        l.GEN_ART_NUMBER,
        l.ST_RANK,
        l.MJ_MBQ,
        l.MJ_REQ,
        cap.ATTR_DIM,
        cap.ATTR_VAL,
        cap.ATTR_REQ,
        cap.ATTR_CONT,
        (cap.ATTR_CONT * l.MJ_MBQ)                                    AS CAP_QTY,
        GREATEST(cap.ATTR_REQ - (cap.ATTR_CONT * l.MJ_MBQ), 0)         AS CLIPPED_QTY,
        CASE WHEN cap.ATTR_REQ > (cap.ATTR_CONT * l.MJ_MBQ) THEN 1
             ELSE 0 END                                                AS IS_BINDING
    FROM V2RETAIL.ARS_GOLD.V_SILVER_LISTING l
    JOIN sess se ON se.SESSION_ID = l.SESSION_ID
    CROSS JOIN LATERAL (
        SELECT 'MERGE_RNG_SEG' AS ATTR_DIM, l.MERGE_RNG_SEG AS ATTR_VAL,
               l.MERGE_RNG_SEG_REQ AS ATTR_REQ, l.MERGE_RNG_SEG_CONT AS ATTR_CONT
        UNION ALL
        SELECT 'RNG_SEG', l.RNG_SEG, l.RNG_SEG_REQ, l.RNG_SEG_CONT
        UNION ALL
        SELECT 'M_YARN_02', l.M_YARN_02, l.M_YARN_02_REQ, l.M_YARN_02_CONT
        UNION ALL
        SELECT 'WEAVE_2', l.WEAVE_2, l.WEAVE_2_REQ, l.WEAVE_2_CONT
        UNION ALL
        SELECT 'FAB', l.FAB, l.FAB_REQ, l.FAB_CONT
        UNION ALL
        SELECT 'CLR', l.CLR, l.CLR_REQ, l.CLR_CONT
        UNION ALL
        SELECT 'M_VND_CD', l.M_VND_CD, l.M_VND_CD_REQ, l.M_VND_CD_CONT
        UNION ALL
        SELECT 'FIT', l.FIT, l.FIT_REQ, l.FIT_CONT
    ) cap
    WHERE l.ELIG_FLAG = 1
      AND l.MJ_MBQ IS NOT NULL
      AND l.MJ_MBQ > 0
),
binding_only AS (
    SELECT *
    FROM binds
    WHERE IS_BINDING = 1
),
-- Modal binding attribute per (session, store, maj_cat)
attr_rank AS (
    SELECT
        SESSION_ID,
        WERKS,
        MAJ_CAT,
        ATTR_DIM,
        COUNT(*)            AS BIND_COUNT,
        SUM(CLIPPED_QTY)    AS TOTAL_CLIPPED,
        ROW_NUMBER() OVER (
            PARTITION BY SESSION_ID, WERKS, MAJ_CAT
            ORDER BY COUNT(*) DESC, SUM(CLIPPED_QTY) DESC, ATTR_DIM
        ) AS RN
    FROM binding_only
    GROUP BY SESSION_ID, WERKS, MAJ_CAT, ATTR_DIM
),
modal_attr AS (
    SELECT SESSION_ID, WERKS, MAJ_CAT, ATTR_DIM, BIND_COUNT, TOTAL_CLIPPED
    FROM attr_rank
    WHERE RN = 1
),
-- Rep article + the dominant ATTR_VAL within the modal attribute
attr_val_rank AS (
    SELECT
        b.SESSION_ID,
        b.WERKS,
        b.MAJ_CAT,
        b.ATTR_DIM,
        b.ATTR_VAL,
        SUM(b.CLIPPED_QTY) AS VAL_CLIPPED,
        COUNT(*)           AS VAL_BIND_COUNT,
        ROW_NUMBER() OVER (
            PARTITION BY b.SESSION_ID, b.WERKS, b.MAJ_CAT, b.ATTR_DIM
            ORDER BY SUM(b.CLIPPED_QTY) DESC, COUNT(*) DESC
        ) AS RN
    FROM binding_only b
    JOIN modal_attr m
      ON m.SESSION_ID = b.SESSION_ID
     AND m.WERKS      = b.WERKS
     AND m.MAJ_CAT    = b.MAJ_CAT
     AND m.ATTR_DIM   = b.ATTR_DIM
    GROUP BY b.SESSION_ID, b.WERKS, b.MAJ_CAT, b.ATTR_DIM, b.ATTR_VAL
),
modal_val AS (
    SELECT SESSION_ID, WERKS, MAJ_CAT, ATTR_DIM, ATTR_VAL, VAL_CLIPPED, VAL_BIND_COUNT
    FROM attr_val_rank
    WHERE RN = 1
),
-- Representative GEN_ART for the alert (largest clipped contributor)
rep_art AS (
    SELECT
        b.SESSION_ID,
        b.WERKS,
        b.MAJ_CAT,
        b.GEN_ART_NUMBER,
        MAX(b.ST_RANK)      AS ST_RANK,
        SUM(b.CLIPPED_QTY)  AS ART_CLIPPED,
        ROW_NUMBER() OVER (
            PARTITION BY b.SESSION_ID, b.WERKS, b.MAJ_CAT
            ORDER BY SUM(b.CLIPPED_QTY) DESC
        ) AS RN
    FROM binding_only b
    JOIN modal_attr m
      ON m.SESSION_ID = b.SESSION_ID
     AND m.WERKS      = b.WERKS
     AND m.MAJ_CAT    = b.MAJ_CAT
     AND m.ATTR_DIM   = b.ATTR_DIM
    GROUP BY b.SESSION_ID, b.WERKS, b.MAJ_CAT, b.GEN_ART_NUMBER
),
rep_art_one AS (
    SELECT * FROM rep_art WHERE RN = 1
),
-- Store priority = normalized ST_RANK over the session-store population.
-- Lower ST_RANK = better store; we invert so high-rank stores get higher priority.
store_prio AS (
    SELECT
        SESSION_ID,
        WERKS,
        COALESCE(
            1.0 - (
                (AVG(ST_RANK) - MIN(ST_RANK) OVER (PARTITION BY SESSION_ID))
                / NULLIF(
                    (MAX(ST_RANK) OVER (PARTITION BY SESSION_ID)
                     - MIN(ST_RANK) OVER (PARTITION BY SESSION_ID)), 0)
            ),
            0.5
        ) AS STORE_PRIORITY
    FROM (
        SELECT SESSION_ID, WERKS, AVG(ST_RANK) AS ST_RANK
        FROM V2RETAIL.ARS_GOLD.V_SILVER_LISTING
        WHERE ST_RANK IS NOT NULL
        GROUP BY SESSION_ID, WERKS
    )
),
-- Majcat priority = share of ship over trailing 30d (V_SILVER_ALLOC).
majcat_prio_base AS (
    SELECT
        a.MAJ_CAT,
        SUM(COALESCE(a.SHIP_QTY, 0)) AS MJ_SHIP_30D
    FROM V2RETAIL.ARS_GOLD.V_SILVER_ALLOC a
    JOIN V2RETAIL.ARS_GOLD.V_SILVER_SESSIONS s
      ON s.SESSION_ID = a.SESSION_ID
    WHERE s.STARTED_AT >= DATEADD('day', -30, CURRENT_DATE)
    GROUP BY a.MAJ_CAT
),
majcat_prio AS (
    SELECT
        MAJ_CAT,
        COALESCE(
            MJ_SHIP_30D / NULLIF(SUM(MJ_SHIP_30D) OVER (), 0),
            0.5
        ) AS MAJCAT_PRIORITY
    FROM majcat_prio_base
),
-- Aggregate alert grain: (session, store, maj_cat, modal attr_dim/val).
alert_base AS (
    SELECT
        se.SESSION_ID,
        se.RUN_DATE,
        m.WERKS,
        m.MAJ_CAT,
        r.GEN_ART_NUMBER,
        mv.ATTR_DIM,
        mv.ATTR_VAL,
        m.TOTAL_CLIPPED          AS LOST_QTY,
        m.BIND_COUNT              AS BINDING_ART_COUNT,
        mv.VAL_BIND_COUNT,
        mv.VAL_CLIPPED
    FROM modal_attr m
    JOIN sess se        ON se.SESSION_ID = m.SESSION_ID
    JOIN modal_val mv
      ON mv.SESSION_ID = m.SESSION_ID
     AND mv.WERKS      = m.WERKS
     AND mv.MAJ_CAT    = m.MAJ_CAT
     AND mv.ATTR_DIM   = m.ATTR_DIM
    LEFT JOIN rep_art_one r
      ON r.SESSION_ID = m.SESSION_ID
     AND r.WERKS      = m.WERKS
     AND r.MAJ_CAT    = m.MAJ_CAT
    WHERE m.TOTAL_CLIPPED > 0
)
SELECT
    'R4'                                                            AS RULE_ID,
    ab.SESSION_ID                                                   AS SESSION_ID,
    ab.RUN_DATE                                                     AS RUN_DATE,
    ab.WERKS                                                        AS STORE,
    ab.MAJ_CAT                                                      AS MAJ_CAT,
    ab.GEN_ART_NUMBER                                               AS GEN_ART_NUMBER,
    NULL                                                            AS VAR_ART,
    ab.ATTR_DIM                                                     AS ATTR_DIM,
    ab.ATTR_VAL                                                     AS ATTR_VAL,
    ab.LOST_QTY                                                     AS LOST_QTY,
    'Grid cap ' || ab.ATTR_DIM || '=' || COALESCE(ab.ATTR_VAL, '?')
        || ' bound the allocation: CONT% * MJ_MBQ < REQ across '
        || ab.BINDING_ART_COUNT
        || ' article(s); clipped ' || CAST(ROUND(ab.LOST_QTY, 0) AS VARCHAR)
        || ' units of demand for ' || ab.MAJ_CAT
        || ' at store ' || ab.WERKS                                 AS ROOT_CAUSE,
    'lift_cap'                                                      AS FIX_ACTION,
    (
        ab.LOST_QTY
        * COALESCE(sp.STORE_PRIORITY, 0.5)
        * COALESCE(mp.MAJCAT_PRIORITY, 0.5)
        * POWER(0.95, DATEDIFF('day', ab.RUN_DATE, CURRENT_DATE))
        * 0.9
    )                                                               AS SEVERITY,
    OBJECT_CONSTRUCT(
        'rule',                'R4_CAP_BIND',
        'binding_attr',        ab.ATTR_DIM,
        'binding_attr_value',  ab.ATTR_VAL,
        'binding_art_count',   ab.BINDING_ART_COUNT,
        'binding_val_count',   ab.VAL_BIND_COUNT,
        'lost_qty',            ab.LOST_QTY,
        'val_clipped_qty',     ab.VAL_CLIPPED,
        'rep_gen_art',         ab.GEN_ART_NUMBER,
        'store_priority',      COALESCE(sp.STORE_PRIORITY, 0.5),
        'majcat_priority',     COALESCE(mp.MAJCAT_PRIORITY, 0.5),
        'recency_decay',       POWER(0.95, DATEDIFF('day', ab.RUN_DATE, CURRENT_DATE)),
        'rule_weight',         0.9,
        'inferred_reason',     'ALLOC_REASON is NULL in source; binding cap inferred from <ATTR>_REQ > <ATTR>_CONT * MJ_MBQ',
        'fix_hint',            'Review Master_CONT_' || ab.ATTR_DIM
                                || ' for MAJ_CAT=' || ab.MAJ_CAT
                                || '; consider raising CONT_PCT for ' || COALESCE(ab.ATTR_VAL, '?')
                                || ' or redistributing MJ_MBQ.'
    )                                                               AS DETAIL_JSON
FROM alert_base ab
LEFT JOIN store_prio sp
       ON sp.SESSION_ID = ab.SESSION_ID
      AND sp.WERKS      = ab.WERKS
LEFT JOIN majcat_prio mp
       ON mp.MAJ_CAT    = ab.MAJ_CAT
;

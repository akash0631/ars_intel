-- =====================================================================
-- Rule: R5 - DC_OOS_GAP
-- Purpose: Detect store-gen_art requirements where the serving RDC has
--          insufficient (or zero) stock at the size/variant level in
--          ARS_MSA_VAR_ART, while a DIFFERENT RDC still holds stock that
--          could be redistributed. This surfaces DC-side out-of-stock
--          gaps that are silently capping listing fulfilment even though
--          the network has inventory.
--
-- Trigger: Store has MJ_REQ > 0 and ELIG_REASON = 'OK' for a gen_art on
--          its assigned RDC, but SUM(STK_QTY) for that gen_art at that
--          RDC is 0 OR less than store-level required qty (proxied by
--          MJ_REQ_NO_EXC), AND some other RDC has STK_QTY > 0 for the
--          same gen_art (redistribution opportunity exists).
--
-- lost_qty: GREATEST( required_qty - rdc_stock_qty , 0 )
--           where required_qty = store MJ_REQ_NO_EXC for that gen_art
--           and rdc_stock_qty  = SUM(STK_QTY) at the store's RDC for
--           that gen_art across all variants.
--
-- Severity:
--   severity = lost_qty
--            * store_priority   -- normalized ST_RANK (1/ST_RANK capped)
--            * majcat_priority  -- majcat 30d ship share from V_SILVER_ALLOC
--            * recency_decay    -- 0.95 ^ DATEDIFF(day, RUN_DATE, today)
--            * 0.8              -- rule weight
--
-- Source: ONLY V2RETAIL.ARS_GOLD silver views.
-- Target: V2RETAIL.ARS_GOLD.MART_ALERTS
-- Notes : ALLOC_REASON is NULL upstream; we infer the reason here from
--         the silver requirement vs DC stock joins. Idempotent on
--         (RULE_ID, SESSION_ID).
-- =====================================================================

DELETE FROM V2RETAIL.ARS_GOLD.MART_ALERTS
WHERE RULE_ID = 'R5'
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
WITH sess AS (
    SELECT SESSION_ID, CAST(STARTED_AT AS DATE) AS RUN_DATE
    FROM V2RETAIL.ARS_GOLD.V_SILVER_SESSIONS
    WHERE STATUS = 'SUCCESS'
      AND STARTED_AT >= DATEADD('day', -7, CURRENT_DATE)
),
-- Store requirements eligible for fulfilment (gen_art level, dedup)
req AS (
    SELECT
        l.SESSION_ID,
        l.WERKS                              AS STORE,
        l.RDC                                AS RDC,
        l.MAJ_CAT,
        l.GEN_ART_NUMBER,
        MAX(l.GEN_ART_DESC)                  AS GEN_ART_DESC,
        MAX(COALESCE(l.MJ_REQ_NO_EXC, l.MJ_REQ, 0))  AS REQ_QTY,
        MAX(l.ST_RANK)                       AS ST_RANK
    FROM V2RETAIL.ARS_GOLD.V_SILVER_LISTING l
    JOIN sess s
      ON s.SESSION_ID = l.SESSION_ID
    WHERE COALESCE(l.MJ_REQ_NO_EXC, l.MJ_REQ, 0) > 0
      AND l.RDC IS NOT NULL
    GROUP BY l.SESSION_ID, l.WERKS, l.RDC, l.MAJ_CAT, l.GEN_ART_NUMBER
),
-- DC stock per gen_art per RDC (already aggregated in V_SILVER_DC_STOCK)
dc_stock AS (
    SELECT
        d.RDC,
        d.GEN_ART_NUMBER,
        SUM(COALESCE(d.STK_QTY_TOTAL, 0))   AS RDC_STK_QTY,
        SUM(COALESCE(d.HOLD_QTY_TOTAL, 0))  AS RDC_HOLD_QTY,
        SUM(COALESCE(d.VAR_ART_COUNT, 0))   AS VAR_COUNT_AT_RDC
    FROM V2RETAIL.ARS_GOLD.V_SILVER_DC_STOCK d
    GROUP BY d.RDC, d.GEN_ART_NUMBER
),
-- Total network stock per gen_art across ALL RDCs (to know if redistribution is possible)
net_stock AS (
    SELECT
        d.GEN_ART_NUMBER,
        SUM(COALESCE(d.STK_QTY_TOTAL, 0)) AS NET_STK_QTY,
        COUNT(DISTINCT CASE WHEN COALESCE(d.STK_QTY_TOTAL, 0) > 0 THEN d.RDC END) AS RDC_WITH_STK
    FROM V2RETAIL.ARS_GOLD.V_SILVER_DC_STOCK d
    GROUP BY d.GEN_ART_NUMBER
),
-- Trailing 30d majcat ship share (majcat_priority)
mc_30d AS (
    SELECT
        a.MAJ_CAT,
        SUM(COALESCE(a.SHIP_QTY, 0)) AS MC_SHIP_30D
    FROM V2RETAIL.ARS_GOLD.V_SILVER_ALLOC a
    JOIN V2RETAIL.ARS_GOLD.V_SILVER_SESSIONS s
      ON s.SESSION_ID = a.SESSION_ID
    WHERE s.STARTED_AT >= DATEADD('day', -30, CURRENT_DATE)
      AND s.STATUS = 'SUCCESS'
    GROUP BY a.MAJ_CAT
),
mc_tot AS (
    SELECT SUM(MC_SHIP_30D) AS TOT_SHIP_30D FROM mc_30d
),
-- Candidate gaps
gap AS (
    SELECT
        r.SESSION_ID,
        r.STORE,
        r.RDC,
        r.MAJ_CAT,
        r.GEN_ART_NUMBER,
        r.GEN_ART_DESC,
        r.REQ_QTY,
        r.ST_RANK,
        COALESCE(ds.RDC_STK_QTY, 0)   AS RDC_STK_QTY,
        COALESCE(ds.RDC_HOLD_QTY, 0)  AS RDC_HOLD_QTY,
        COALESCE(ds.VAR_COUNT_AT_RDC, 0) AS VAR_COUNT_AT_RDC,
        COALESCE(ns.NET_STK_QTY, 0)   AS NET_STK_QTY,
        COALESCE(ns.RDC_WITH_STK, 0)  AS RDC_WITH_STK,
        GREATEST(r.REQ_QTY - COALESCE(ds.RDC_STK_QTY, 0), 0) AS LOST_QTY
    FROM req r
    LEFT JOIN dc_stock ds
      ON ds.RDC = r.RDC
     AND ds.GEN_ART_NUMBER = r.GEN_ART_NUMBER
    LEFT JOIN net_stock ns
      ON ns.GEN_ART_NUMBER = r.GEN_ART_NUMBER
    WHERE
        -- serving RDC is short (zero OR < required)
        COALESCE(ds.RDC_STK_QTY, 0) < r.REQ_QTY
        -- and at least one OTHER RDC has stock (redistribution possible)
        AND COALESCE(ns.NET_STK_QTY, 0) > COALESCE(ds.RDC_STK_QTY, 0)
        AND COALESCE(ns.RDC_WITH_STK, 0) >= 1
)
SELECT
    'R5'                                     AS RULE_ID,
    g.SESSION_ID                             AS SESSION_ID,
    s.RUN_DATE                               AS RUN_DATE,
    g.STORE                                  AS STORE,
    g.MAJ_CAT                                AS MAJ_CAT,
    g.GEN_ART_NUMBER                         AS GEN_ART_NUMBER,
    NULL                                     AS VAR_ART,
    'RDC'                                    AS ATTR_DIM,
    g.RDC                                    AS ATTR_VAL,
    g.LOST_QTY                               AS LOST_QTY,
    CASE
        WHEN g.RDC_STK_QTY = 0 AND g.NET_STK_QTY > 0
            THEN 'Serving RDC ' || g.RDC || ' has ZERO stock for gen_art ' || g.GEN_ART_NUMBER
                 || ' but ' || g.RDC_WITH_STK || ' other RDC(s) hold ' || g.NET_STK_QTY
                 || ' units - redistributable'
        WHEN g.RDC_STK_QTY < g.REQ_QTY
            THEN 'Serving RDC ' || g.RDC || ' short by ' || g.LOST_QTY
                 || ' units (have ' || g.RDC_STK_QTY || ', need ' || g.REQ_QTY
                 || ') - network has ' || g.NET_STK_QTY || ' across ' || g.RDC_WITH_STK || ' RDC(s)'
        ELSE 'DC stock gap on RDC ' || g.RDC || ' for gen_art ' || g.GEN_ART_NUMBER
    END                                      AS ROOT_CAUSE,
    'dc_redistribute'                        AS FIX_ACTION,
    (
        g.LOST_QTY
        * COALESCE(LEAST(1.0, 1.0 / NULLIF(g.ST_RANK, 0)), 0.5)
        * COALESCE(
              (SELECT mc.MC_SHIP_30D / NULLIF(mt.TOT_SHIP_30D, 0)
               FROM mc_30d mc CROSS JOIN mc_tot mt
               WHERE mc.MAJ_CAT = g.MAJ_CAT),
              0.5
          )
        * POWER(0.95, DATEDIFF('day', s.RUN_DATE, CURRENT_DATE))
        * 0.8
    )                                        AS SEVERITY,
    OBJECT_CONSTRUCT(
        'rule',              'R5',
        'rule_name',         'DC_OOS_GAP',
        'store',             g.STORE,
        'rdc',               g.RDC,
        'maj_cat',           g.MAJ_CAT,
        'gen_art_number',    g.GEN_ART_NUMBER,
        'gen_art_desc',      g.GEN_ART_DESC,
        'req_qty',           g.REQ_QTY,
        'rdc_stk_qty',       g.RDC_STK_QTY,
        'rdc_hold_qty',      g.RDC_HOLD_QTY,
        'var_count_at_rdc',  g.VAR_COUNT_AT_RDC,
        'net_stk_qty',       g.NET_STK_QTY,
        'rdc_with_stk',      g.RDC_WITH_STK,
        'lost_qty',          g.LOST_QTY,
        'st_rank',           g.ST_RANK,
        'inferred_reason',   CASE
                                 WHEN g.RDC_STK_QTY = 0 THEN 'RDC_ZERO_STOCK'
                                 ELSE 'RDC_PARTIAL_STOCK'
                             END,
        'redistribution',    CASE
                                 WHEN g.NET_STK_QTY > g.RDC_STK_QTY THEN 'POSSIBLE'
                                 ELSE 'NONE'
                             END,
        'run_date',          s.RUN_DATE
    )                                        AS DETAIL_JSON
FROM gap g
JOIN sess s ON s.SESSION_ID = g.SESSION_ID
WHERE g.LOST_QTY > 0;

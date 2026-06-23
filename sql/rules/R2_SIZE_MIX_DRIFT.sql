-------------------------------------------------------------------------------
-- Rule R2: SIZE_MIX_DRIFT
-------------------------------------------------------------------------------
-- Detects allocation rounds where the SIZE mix shipped to a store-majcat
-- diverges materially from the actual demand size mix observed in the
-- trailing 7 days of POS sales (ET_SALES_DATA).
--
-- Method
--   * Demand size mix (per store x majcat): sum L-7d sales QTY by SZ from
--     ET_SALES_DATA joined to MASTER_PRODUCT. If no L-7d sales, fall back to
--     Master_CONT_SZ (baseline contribution % per majcat x SZ) so brand-new
--     stores / dead majcats still get a sensible expected vector.
--   * Sent size mix (per store x majcat): sum SHIP_QTY from
--     V_SILVER_ALLOC -> MASTER_PRODUCT (VAR_ART -> SZ) for the run.
--   * Distance: Chi-square style: SUM( (sent_pct - demand_pct)^2 /
--     NULLIF(demand_pct, 0) ) across all SZ buckets. Flag if > 0.20.
--
-- LOST_QTY meaning
--   Sum of |sent_qty - expected_qty| for the SZ buckets where sent_pct
--   exceeds demand_pct (i.e. units shipped into the wrong size bucket --
--   units that won't sell because the store needed a different size).
--
-- Notes
--   * Reads from V2RETAIL.ARS_GOLD silver views only (no BRONZE).
--   * ALLOC_REASON is always NULL in source -> we INFER from joins to
--     MASTER_PRODUCT / Master_CONT_SZ.
--   * Severity = lost_qty * store_priority * majcat_priority * recency_decay
--                * 0.7 (rule weight).
--   * Store priority: normalized ST_RANK from V_SILVER_LISTING (fallback 0.5).
--   * Majcat priority: ship-share over trailing 30d from V_SILVER_ALLOC
--     (fallback 0.5).
--   * Recency decay: POWER(0.95, days_since_run).
--   * Idempotent: leading DELETE scoped to RULE_ID='R2' + this run's sessions.
-------------------------------------------------------------------------------

-- Idempotent cleanup: remove any prior R2 rows for the sessions in scope
DELETE FROM V2RETAIL.ARS_GOLD.MART_ALERTS
WHERE RULE_ID = 'R2'
  AND SESSION_ID IN (
    SELECT DISTINCT s.SESSION_ID
    FROM V2RETAIL.ARS_GOLD.V_SILVER_SESSIONS s
    WHERE s.STATUS = 'SUCCESS'
      AND s.STARTED_AT >= DATEADD('day', -7, CURRENT_DATE)
  );

INSERT INTO V2RETAIL.ARS_GOLD.MART_ALERTS (
  RULE_ID, SESSION_ID, RUN_DATE, STORE, MAJ_CAT, GEN_ART_NUMBER, VAR_ART,
  ATTR_DIM, ATTR_VAL, LOST_QTY, ROOT_CAUSE, FIX_ACTION, SEVERITY, DETAIL_JSON
)
WITH
-- ---------------------------------------------------------------------------
-- 1. In-scope sessions (last 7 days of successful runs)
-- ---------------------------------------------------------------------------
sessions_scope AS (
  SELECT
    s.SESSION_ID,
    CAST(s.STARTED_AT AS DATE) AS RUN_DATE
  FROM V2RETAIL.ARS_GOLD.V_SILVER_SESSIONS s
  WHERE s.STATUS = 'SUCCESS'
    AND s.STARTED_AT >= DATEADD('day', -7, CURRENT_DATE)
),

-- ---------------------------------------------------------------------------
-- 2. Sent size mix from allocation (silver) joined to product master
-- ---------------------------------------------------------------------------
sent_by_size AS (
  SELECT
    a.SESSION_ID,
    a.WERKS                       AS STORE,
    mp.MAJ_CAT,
    a.GEN_ART_NUMBER,
    mp.SZ,
    SUM(COALESCE(a.SHIP_QTY, 0))  AS SENT_QTY
  FROM V2RETAIL.ARS_GOLD.V_SILVER_ALLOC a
  JOIN sessions_scope sc
    ON sc.SESSION_ID = a.SESSION_ID
  JOIN V2RETAIL.ARS_BRONZE.MASTER_PRODUCT mp
    ON TRY_CAST(mp.ARTICLE_NUMBER AS STRING) = TRY_CAST(a.VAR_ART AS STRING)
  WHERE COALESCE(a.SHIP_QTY, 0) > 0
    AND mp.SZ IS NOT NULL
  GROUP BY a.SESSION_ID, a.WERKS, mp.MAJ_CAT, a.GEN_ART_NUMBER, mp.SZ
),

sent_totals AS (
  SELECT
    SESSION_ID, STORE, MAJ_CAT, GEN_ART_NUMBER,
    SUM(SENT_QTY) AS SENT_TOTAL
  FROM sent_by_size
  GROUP BY SESSION_ID, STORE, MAJ_CAT, GEN_ART_NUMBER
),

-- ---------------------------------------------------------------------------
-- 3. L-7d demand size mix from ET_SALES_DATA
-- ---------------------------------------------------------------------------
sales_by_size AS (
  SELECT
    es.WERKS                     AS STORE,
    mp.MAJ_CAT,
    mp.SZ,
    SUM(COALESCE(es.QTY, 0))     AS DEMAND_QTY
  FROM V2RETAIL.ARS_BRONZE.ET_SALES_DATA es
  JOIN V2RETAIL.ARS_BRONZE.MASTER_PRODUCT mp
    ON TRY_CAST(mp.ARTICLE_NUMBER AS STRING) = TRY_CAST(es.MATNR AS STRING)
  WHERE es.DATE >= DATEADD('day', -7, CURRENT_DATE)
    AND mp.SZ IS NOT NULL
  GROUP BY es.WERKS, mp.MAJ_CAT, mp.SZ
),

sales_totals AS (
  SELECT STORE, MAJ_CAT, SUM(DEMAND_QTY) AS DEMAND_TOTAL
  FROM sales_by_size
  GROUP BY STORE, MAJ_CAT
),

-- ---------------------------------------------------------------------------
-- 4. Baseline size mix from Master_CONT_SZ (fallback when no sales)
-- ---------------------------------------------------------------------------
cont_sz AS (
  SELECT
    MAJ_CAT,
    SZ,
    CONT_PCT
  FROM V2RETAIL.ARS_BRONZE.MASTER_CONT_SZ
  WHERE SZ IS NOT NULL
),

-- ---------------------------------------------------------------------------
-- 5. Expected size mix per store x majcat
--    Use L-7d sales mix if DEMAND_TOTAL > 0 else fall back to Master_CONT_SZ.
-- ---------------------------------------------------------------------------
expected_mix AS (
  SELECT
    st.STORE,
    st.MAJ_CAT,
    sbs.SZ,
    CASE WHEN st.DEMAND_TOTAL > 0
         THEN sbs.DEMAND_QTY / st.DEMAND_TOTAL
         ELSE NULL
    END                              AS DEMAND_PCT,
    'SALES_L7D'                      AS DEMAND_SOURCE
  FROM sales_totals st
  JOIN sales_by_size sbs
    ON sbs.STORE = st.STORE AND sbs.MAJ_CAT = st.MAJ_CAT
  WHERE st.DEMAND_TOTAL > 0
  UNION ALL
  -- baseline fallback: stores x majcats with zero L-7d sales
  SELECT
    s.STORE,
    s.MAJ_CAT,
    c.SZ,
    c.CONT_PCT / 100.0               AS DEMAND_PCT,
    'BASELINE_CONT_SZ'               AS DEMAND_SOURCE
  FROM (
    SELECT DISTINCT STORE, MAJ_CAT FROM sent_totals
  ) s
  LEFT JOIN sales_totals st
    ON st.STORE = s.STORE AND st.MAJ_CAT = s.MAJ_CAT
  JOIN cont_sz c
    ON c.MAJ_CAT = s.MAJ_CAT
  WHERE COALESCE(st.DEMAND_TOTAL, 0) = 0
),

-- ---------------------------------------------------------------------------
-- 6. Per (session, store, majcat, gen_art, SZ): align sent vs expected
-- ---------------------------------------------------------------------------
mix_aligned AS (
  SELECT
    st.SESSION_ID,
    st.STORE,
    st.MAJ_CAT,
    st.GEN_ART_NUMBER,
    COALESCE(s.SZ, e.SZ)                           AS SZ,
    COALESCE(s.SENT_QTY, 0)                        AS SENT_QTY,
    st.SENT_TOTAL,
    CASE WHEN st.SENT_TOTAL > 0
         THEN COALESCE(s.SENT_QTY, 0) / st.SENT_TOTAL
         ELSE 0
    END                                            AS SENT_PCT,
    COALESCE(e.DEMAND_PCT, 0)                      AS DEMAND_PCT,
    MAX(e.DEMAND_SOURCE) OVER (
      PARTITION BY st.SESSION_ID, st.STORE, st.MAJ_CAT, st.GEN_ART_NUMBER
    )                                              AS DEMAND_SOURCE
  FROM sent_totals st
  LEFT JOIN sent_by_size s
    ON  s.SESSION_ID    = st.SESSION_ID
    AND s.STORE         = st.STORE
    AND s.MAJ_CAT       = st.MAJ_CAT
    AND s.GEN_ART_NUMBER = st.GEN_ART_NUMBER
  FULL OUTER JOIN expected_mix e
    ON  e.STORE   = st.STORE
    AND e.MAJ_CAT = st.MAJ_CAT
    AND e.SZ      = s.SZ
  WHERE st.SENT_TOTAL > 0
),

-- ---------------------------------------------------------------------------
-- 7. Chi-square distance + lost_qty per (session, store, majcat, gen_art)
-- ---------------------------------------------------------------------------
drift_stats AS (
  SELECT
    SESSION_ID,
    STORE,
    MAJ_CAT,
    GEN_ART_NUMBER,
    ANY_VALUE(SENT_TOTAL)                          AS SENT_TOTAL,
    ANY_VALUE(DEMAND_SOURCE)                       AS DEMAND_SOURCE,
    SUM(
      CASE WHEN DEMAND_PCT > 0
           THEN POWER(SENT_PCT - DEMAND_PCT, 2) / DEMAND_PCT
           ELSE 0
      END
    )                                              AS CHI_SQ,
    SUM(
      CASE WHEN SENT_PCT > DEMAND_PCT
           THEN (SENT_PCT - DEMAND_PCT) * ANY_VALUE(SENT_TOTAL) OVER (
                  PARTITION BY SESSION_ID, STORE, MAJ_CAT, GEN_ART_NUMBER
                )
           ELSE 0
      END
    )                                              AS LOST_QTY_RAW,
    OBJECT_AGG(
      CAST(SZ AS STRING),
      OBJECT_CONSTRUCT(
        'sent_qty',  SENT_QTY,
        'sent_pct',  ROUND(SENT_PCT, 4),
        'demand_pct', ROUND(DEMAND_PCT, 4)
      )
    )                                              AS MIX_DETAIL
  FROM mix_aligned
  GROUP BY SESSION_ID, STORE, MAJ_CAT, GEN_ART_NUMBER
),

drift_flagged AS (
  SELECT
    d.*,
    ROUND(d.LOST_QTY_RAW, 2) AS LOST_QTY
  FROM drift_stats d
  WHERE d.CHI_SQ > 0.20
    AND d.LOST_QTY_RAW > 0
),

-- ---------------------------------------------------------------------------
-- 8. Store priority: normalized ST_RANK from V_SILVER_LISTING
-- ---------------------------------------------------------------------------
store_rank_raw AS (
  SELECT
    l.WERKS                AS STORE,
    AVG(TRY_CAST(l.ST_RANK AS DOUBLE)) AS ST_RANK_AVG
  FROM V2RETAIL.ARS_GOLD.V_SILVER_LISTING l
  WHERE l.ST_RANK IS NOT NULL
  GROUP BY l.WERKS
),

store_rank_bounds AS (
  SELECT MIN(ST_RANK_AVG) AS MIN_R, MAX(ST_RANK_AVG) AS MAX_R
  FROM store_rank_raw
),

store_priority AS (
  SELECT
    r.STORE,
    CASE
      WHEN b.MAX_R = b.MIN_R OR b.MAX_R IS NULL THEN 0.5
      ELSE 1.0 - ((r.ST_RANK_AVG - b.MIN_R) / NULLIF(b.MAX_R - b.MIN_R, 0))
    END AS STORE_PRIORITY
  FROM store_rank_raw r
  CROSS JOIN store_rank_bounds b
),

-- ---------------------------------------------------------------------------
-- 9. Majcat priority: ship-share over last 30d from V_SILVER_ALLOC
-- ---------------------------------------------------------------------------
majcat_ship_30d AS (
  SELECT
    mp.MAJ_CAT,
    SUM(COALESCE(a.SHIP_QTY, 0)) AS SHIP_30D
  FROM V2RETAIL.ARS_GOLD.V_SILVER_ALLOC a
  JOIN V2RETAIL.ARS_GOLD.V_SILVER_SESSIONS s
    ON s.SESSION_ID = a.SESSION_ID
  JOIN V2RETAIL.ARS_BRONZE.MASTER_PRODUCT mp
    ON TRY_CAST(mp.ARTICLE_NUMBER AS STRING) = TRY_CAST(a.VAR_ART AS STRING)
  WHERE s.STARTED_AT >= DATEADD('day', -30, CURRENT_DATE)
  GROUP BY mp.MAJ_CAT
),

majcat_priority AS (
  SELECT
    MAJ_CAT,
    CASE WHEN SUM(SHIP_30D) OVER () > 0
         THEN SHIP_30D / SUM(SHIP_30D) OVER ()
         ELSE 0.5
    END AS MAJCAT_PRIORITY
  FROM majcat_ship_30d
)

-- ---------------------------------------------------------------------------
-- 10. Final projection -> MART_ALERTS
-- ---------------------------------------------------------------------------
SELECT
  'R2'                                          AS RULE_ID,
  df.SESSION_ID,
  sc.RUN_DATE,
  df.STORE,
  df.MAJ_CAT,
  df.GEN_ART_NUMBER,
  CAST(NULL AS STRING)                          AS VAR_ART,
  'SZ'                                          AS ATTR_DIM,
  CAST(NULL AS STRING)                          AS ATTR_VAL,
  df.LOST_QTY,
  -- Business-meaningful root cause string (inferred from joins)
  'Shipped size mix diverges from L-7d demand (chi-sq ' ||
    TO_VARCHAR(ROUND(df.CHI_SQ, 3)) ||
    ' > 0.20; baseline=' || COALESCE(df.DEMAND_SOURCE, 'UNKNOWN') ||
    '). Approx ' || TO_VARCHAR(df.LOST_QTY) ||
    ' units shipped into wrong size buckets for store ' || df.STORE ||
    ' / majcat ' || df.MAJ_CAT || ' / gen_art ' ||
    TO_VARCHAR(df.GEN_ART_NUMBER) || '.'        AS ROOT_CAUSE,
  -- Drift in shipped size assortment is a DC-side packing problem
  'dc_redistribute'                             AS FIX_ACTION,
  -- Severity per spec: lost_qty * store * majcat * recency * weight
  df.LOST_QTY
    * COALESCE(sp.STORE_PRIORITY, 0.5)
    * COALESCE(mcp.MAJCAT_PRIORITY, 0.5)
    * POWER(0.95, DATEDIFF('day', sc.RUN_DATE, CURRENT_DATE))
    * 0.7                                       AS SEVERITY,
  OBJECT_CONSTRUCT(
    'chi_sq',          ROUND(df.CHI_SQ, 4),
    'threshold',       0.20,
    'sent_total',      df.SENT_TOTAL,
    'lost_qty',        df.LOST_QTY,
    'demand_source',   df.DEMAND_SOURCE,
    'size_mix',        df.MIX_DETAIL,
    'store_priority',  ROUND(COALESCE(sp.STORE_PRIORITY, 0.5), 4),
    'majcat_priority', ROUND(COALESCE(mcp.MAJCAT_PRIORITY, 0.5), 4),
    'recency_decay',   ROUND(POWER(0.95,
                          DATEDIFF('day', sc.RUN_DATE, CURRENT_DATE)), 4),
    'rule_weight',     0.7
  )                                             AS DETAIL_JSON
FROM drift_flagged df
JOIN sessions_scope sc
  ON sc.SESSION_ID = df.SESSION_ID
LEFT JOIN store_priority sp
  ON sp.STORE = df.STORE
LEFT JOIN majcat_priority mcp
  ON mcp.MAJ_CAT = df.MAJ_CAT
;

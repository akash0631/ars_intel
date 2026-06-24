-- ============================================================================
-- MART_DRILL_SESSION
-- ----------------------------------------------------------------------------
-- Drill-down view: per (SESSION_ID, STORE, MAJ_CAT) summary of alerts joined
-- back to V_SILVER_LISTING for the underlying listing-engine context fields
-- (MJ_REQ, MJ_MBQ, ELIG_REASON, etc).
--
-- Use case: UI click on a session/store/majcat tile -> open this view filtered
-- by SESSION_ID + STORE + MAJ_CAT to see what alerts fired and the listing
-- engine signals behind each gen_art.
-- ============================================================================

CREATE OR REPLACE VIEW V2RETAIL.ARS_GOLD.MART_DRILL_SESSION AS
WITH alerts_scoped AS (
    SELECT
        SESSION_ID,
        STORE,
        MAJ_CAT,
        GEN_ART_NUMBER,
        RULE_ID,
        SEVERITY,
        LOST_QTY,
        RUN_DATE
    FROM V2RETAIL.ARS_GOLD.MART_ALERTS
    WHERE SESSION_ID IS NOT NULL
      AND RUN_DATE >= DATEADD(day, -14, CURRENT_DATE())
),
alert_agg AS (
    -- store x majcat x gen_art level alert summary
    SELECT
        SESSION_ID,
        STORE,
        MAJ_CAT,
        GEN_ART_NUMBER,
        COUNT(*)                              AS alert_count,
        SUM(COALESCE(SEVERITY, 0))            AS total_severity,
        SUM(COALESCE(LOST_QTY, 0))            AS total_lost_qty,
        MAX(SEVERITY)                         AS max_severity,
        LISTAGG(DISTINCT RULE_ID, ',') WITHIN GROUP (ORDER BY RULE_ID) AS rules_fired,
        MAX(RUN_DATE)                         AS last_run_date
    FROM alerts_scoped
    GROUP BY SESSION_ID, STORE, MAJ_CAT, GEN_ART_NUMBER
),
listing_ctx AS (
    -- one row per (session, store, majcat, gen_art) from silver listing
    -- V_SILVER_LISTING exposes WERKS; alias to STORE so the downstream
    -- join matches MART_ALERTS.STORE.
    SELECT
        SESSION_ID,
        WERKS                    AS STORE,
        MAJ_CAT,
        GEN_ART_NUMBER,
        ANY_VALUE(GEN_ART_DESC)  AS GEN_ART_DESC,
        ANY_VALUE(CLR)           AS CLR,
        MAX(MJ_REQ)              AS MJ_REQ,
        MAX(MJ_MBQ)              AS MJ_MBQ,
        MAX(MJ_DISP_Q)           AS MJ_DISP_Q,
        MAX(MJ_STK_TTL)          AS MJ_STK_TTL,
        MAX(MJ_OPT_CNT)          AS MJ_OPT_CNT,
        MAX(MJ_CONT)             AS MJ_CONT,
        MAX(STK_TTL)             AS ART_STK_TTL,
        MAX(STR)                 AS ART_STR,
        MAX(OPT_REQ)             AS OPT_REQ,
        MAX(OPT_MBQ)             AS OPT_MBQ,
        MAX(PER_OPT_SALE)        AS PER_OPT_SALE,
        MAX(ELIG_FLAG)           AS ELIG_FLAG,
        MAX(CASE WHEN ELIG_REASON <> 'OK' THEN ELIG_REASON END)            AS ELIG_REASON_BLOCKING,
        ANY_VALUE(ELIG_REASON)                                             AS ELIG_REASON_ANY,
        MAX(LISTING)             AS LISTING,
        MAX(IS_NEW)              AS IS_NEW,
        MAX(OPT_TYPE)            AS OPT_TYPE,
        MAX(AGE)                 AS AGE,
        MAX(EXCESS_STK)          AS EXCESS_STK,
        MAX(ART_EXCESS)          AS ART_EXCESS
    FROM V2RETAIL.ARS_GOLD.V_SILVER_LISTING
    GROUP BY SESSION_ID, WERKS, MAJ_CAT, GEN_ART_NUMBER
),
joined AS (
    SELECT
        a.SESSION_ID,
        a.STORE,
        a.MAJ_CAT,
        a.GEN_ART_NUMBER,
        a.alert_count,
        a.total_severity,
        a.total_lost_qty,
        a.max_severity,
        a.rules_fired,
        a.last_run_date,

        l.GEN_ART_DESC,
        l.CLR,
        l.MJ_REQ,
        l.MJ_MBQ,
        l.MJ_DISP_Q,
        l.MJ_STK_TTL,
        l.MJ_OPT_CNT,
        l.MJ_CONT,
        l.ART_STK_TTL,
        l.ART_STR,
        l.OPT_REQ,
        l.OPT_MBQ,
        l.PER_OPT_SALE,
        l.ELIG_FLAG,
        COALESCE(l.ELIG_REASON_BLOCKING, l.ELIG_REASON_ANY) AS ELIG_REASON,
        l.LISTING,
        l.IS_NEW,
        l.OPT_TYPE,
        l.AGE,
        l.EXCESS_STK,
        l.ART_EXCESS
    FROM alert_agg a
    LEFT JOIN listing_ctx l
        ON  l.SESSION_ID      = a.SESSION_ID
        AND l.STORE           = a.STORE
        AND l.MAJ_CAT         = a.MAJ_CAT
        AND l.GEN_ART_NUMBER  = a.GEN_ART_NUMBER
)
SELECT
    j.*,
    spm.ST_NM        AS STORE_NAME,
    spm.ZONE         AS STORE_ZONE,
    spm.STATE        AS STORE_STATE,
    -- store x majcat rollup aggregates (window over the drill grain)
    SUM(j.alert_count)    OVER (PARTITION BY j.SESSION_ID, j.STORE, j.MAJ_CAT) AS smc_alert_count,
    SUM(j.total_severity) OVER (PARTITION BY j.SESSION_ID, j.STORE, j.MAJ_CAT) AS smc_total_severity,
    SUM(j.total_lost_qty) OVER (PARTITION BY j.SESSION_ID, j.STORE, j.MAJ_CAT) AS smc_total_lost_qty,
    -- session rollup aggregates
    SUM(j.alert_count)    OVER (PARTITION BY j.SESSION_ID) AS sess_alert_count,
    SUM(j.total_severity) OVER (PARTITION BY j.SESSION_ID) AS sess_total_severity,
    SUM(j.total_lost_qty) OVER (PARTITION BY j.SESSION_ID) AS sess_total_lost_qty
FROM joined j
LEFT JOIN V2RETAIL.ARS_BRONZE.STORE_PLANT_MASTER spm
    ON spm.ST_CD = j.STORE
ORDER BY j.SESSION_ID, j.STORE, j.MAJ_CAT, j.total_severity DESC;

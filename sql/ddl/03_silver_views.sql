-- ars_intel: silver views in ARS_GOLD
-- Bronze schema discovered after load — projection-only, minimal enrichment.

USE SCHEMA V2RETAIL.ARS_GOLD;

-- ---------------------------------------------------------------------------
-- V_SILVER_SESSIONS
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_SILVER_SESSIONS AS
SELECT
    s.SESSION_ID,
    TO_TIMESTAMP_NTZ(s.STARTED_AT, 9)                AS STARTED_AT,
    TO_TIMESTAMP_NTZ(s.COMPLETED_AT, 9)              AS FINISHED_AT,
    CAST(TO_TIMESTAMP_NTZ(s.STARTED_AT, 9) AS DATE)  AS RUN_DATE,
    HOUR(TO_TIMESTAMP_NTZ(s.STARTED_AT, 9))          AS RUN_HOUR,
    s.STATUS,
    s.ALLOCATION_MODE,
    s.MAJCAT_COUNT,
    s.ALLOC_ROWS,
    s.SHIP_QTY_TOTAL,
    s.HOLD_QTY_TOTAL,
    CAST(NULL AS NUMBER)                             AS FAILED_MAJCATS,
    CAST(NULL AS STRING)                             AS PARKED_STATUS
FROM V2RETAIL.ARS_BRONZE.ARS_LISTING_SESSIONS s;

-- ---------------------------------------------------------------------------
-- V_SILVER_SESSION_MAJCAT
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_SILVER_SESSION_MAJCAT AS
SELECT
    s.SESSION_ID,
    TO_TIMESTAMP_NTZ(s.STARTED_AT, 9)                AS STARTED_AT,
    CAST(TO_TIMESTAMP_NTZ(s.STARTED_AT, 9) AS DATE)  AS RUN_DATE,
    HOUR(TO_TIMESTAMP_NTZ(s.STARTED_AT, 9))          AS RUN_HOUR,
    s.STATUS                                         AS SESSION_STATUS,
    s.ALLOCATION_MODE,
    q.MAJ_CAT,
    q.STATUS                                         AS MAJCAT_STATUS,
    q.ERROR_MSG                                      AS MAJCAT_ERROR_MSG,
    q.SHIP_QTY                                       AS MAJCAT_SHIP_QTY,
    q.HOLD_QTY                                       AS MAJCAT_HOLD_QTY,
    q.ROWS_AFFECTED                                  AS MAJCAT_ROWS_AFFECTED,
    q.ATTEMPTS                                       AS MAJCAT_ATTEMPTS,
    q.DURATION_SEC                                   AS MAJCAT_DURATION_SEC,
    q.OPT_COUNT                                      AS MAJCAT_OPT_COUNT,
    TO_TIMESTAMP_NTZ(q.PICKED_AT, 9)                 AS MAJCAT_PICKED_AT,
    TO_TIMESTAMP_NTZ(q.COMPLETED_AT, 9)              AS MAJCAT_COMPLETED_AT,
    q.WORKER_ID                                      AS MAJCAT_WORKER_ID
FROM V2RETAIL.ARS_BRONZE.ARS_LISTING_SESSIONS s
LEFT JOIN V2RETAIL.ARS_BRONZE.ARS_ALLOC_MAJCAT_QUEUE q
       ON TO_TIMESTAMP_NTZ(q.CREATED_AT, 9)
          BETWEEN DATEADD('hour', -1, TO_TIMESTAMP_NTZ(s.STARTED_AT, 9))
              AND DATEADD('hour',  6, TO_TIMESTAMP_NTZ(s.STARTED_AT, 9));

-- ---------------------------------------------------------------------------
-- V_SILVER_LISTING — bronze-direct projection (STORE master has no usable join)
-- ELIG_FLAG/REASON not in source: infer from MJ_REQ + STK_TTL.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_SILVER_LISTING AS
SELECT
    lh.SESSION_ID,
    TO_TIMESTAMP_NTZ(lh.PARKED_AT, 9)                AS PARKED_AT,
    TO_TIMESTAMP_NTZ(lh.APPROVED_AT, 9)              AS APPROVED_AT,
    lh.APPROVED_BY,
    lh.WERKS,
    COALESCE(sp.ST_NM, lh.WERKS)                     AS STORE_NAME,
    lh.RDC,
    lh.ST_RANK,
    GREATEST(0.05, LEAST(1.0,
        1.0 - (COALESCE(lh.ST_RANK, 20) - 1) * 0.05))                 AS STORE_PRIORITY,
    lh.MAJ_CAT,
    lh.GEN_ART_NUMBER,
    lh.MAJ_CAT                                       AS MAJ_CAT_CANON,
    lh.CLR,
    lh.FAB,
    CAST(NULL AS STRING)                             AS FIT,
    lh.RNG_SEG,
    lh.MERGE_RNG_SEG,
    lh.M_VND_CD,
    lh.M_YARN_02,
    lh.WEAVE_2,
    lh.GEN_ART_DESC,
    mp.MRP,
    mp.SSN,
    lh.IS_NEW,
    lh.OPT_TYPE,
    lh.ST_STK_V06_QTY,
    lh.ST_STK_V07_QTY,
    lh.STK_TTL,
    lh.STR,
    lh.AUTO_GEN_ART_SALE,
    lh.AGE,
    lh.FOCUS_W_CAP,
    lh.FOCUS_WO_CAP,
    lh.I_ROD,
    lh.LISTING,
    lh.RL_HOLD_QTY,
    lh.MSA_FNL_Q,
    lh.VAR_COUNT,
    lh.VAR_FNL_COUNT,
    lh.MJ_STK_TTL, lh.MJ_STR, lh.MJ_CONT, lh.MJ_MBQ, lh.MJ_OPT_CNT,
    lh.MJ_DISP_Q, lh.MJ_REQ, lh.MJ_REQ_WITH_EXC, lh.MJ_REQ_NO_EXC,
    lh.MERGE_RNG_SEG_STK_TTL, lh.MERGE_RNG_SEG_STR, lh.MERGE_RNG_SEG_CONT,
    lh.MERGE_RNG_SEG_MBQ, lh.MERGE_RNG_SEG_OPT_CNT, lh.MERGE_RNG_SEG_DISP_Q,
    lh.MERGE_RNG_SEG_REQ,
    lh.RNG_SEG_STK_TTL, lh.RNG_SEG_STR, lh.RNG_SEG_CONT,
    lh.RNG_SEG_MBQ, lh.RNG_SEG_OPT_CNT, lh.RNG_SEG_DISP_Q,
    lh.RNG_SEG_REQ,
    lh.M_YARN_02_STK_TTL, lh.M_YARN_02_STR, lh.M_YARN_02_CONT,
    lh.M_YARN_02_MBQ, lh.M_YARN_02_OPT_CNT, lh.M_YARN_02_DISP_Q,
    lh.M_YARN_02_REQ,
    lh.WEAVE_2_STK_TTL, lh.WEAVE_2_STR, lh.WEAVE_2_CONT,
    lh.WEAVE_2_MBQ, lh.WEAVE_2_OPT_CNT, lh.WEAVE_2_DISP_Q,
    lh.WEAVE_2_REQ,
    lh.FAB_STK_TTL, lh.FAB_STR, lh.FAB_CONT,
    lh.FAB_MBQ, lh.FAB_OPT_CNT, lh.FAB_DISP_Q,
    lh.FAB_REQ,
    lh.CLR_STK_TTL, lh.CLR_STR, lh.CLR_CONT,
    lh.CLR_MBQ, lh.CLR_OPT_CNT, lh.CLR_DISP_Q,
    lh.CLR_REQ,
    lh.M_VND_CD_STK_TTL, lh.M_VND_CD_STR, lh.M_VND_CD_CONT,
    lh.M_VND_CD_MBQ, lh.M_VND_CD_OPT_CNT, lh.M_VND_CD_DISP_Q,
    lh.M_VND_CD_REQ,
    CAST(NULL AS FLOAT) AS FIT_STK_TTL,
    CAST(NULL AS FLOAT) AS FIT_STR,
    CAST(NULL AS FLOAT) AS FIT_CONT,
    CAST(NULL AS FLOAT) AS FIT_MBQ,
    CAST(NULL AS FLOAT) AS FIT_OPT_CNT,
    CAST(NULL AS FLOAT) AS FIT_DISP_Q,
    CAST(NULL AS FLOAT) AS FIT_REQ,
    lh.PER_OPT_SALE, lh.OPT_MBQ, lh.OPT_REQ, lh.EXCESS_STK, lh.ART_EXCESS,
    CASE WHEN lh.MJ_REQ > 0 AND lh.STK_TTL > 0 THEN 1 ELSE 0 END AS ELIG_FLAG,
    CASE
      WHEN lh.MJ_REQ <= 0  THEN 'NO_DEMAND'
      WHEN lh.STK_TTL <= 0 THEN 'NO_STOCK'
      WHEN lh.LISTING IS NULL OR lh.LISTING = 0 THEN 'NOT_LISTED'
      ELSE 'OK'
    END                                                                 AS ELIG_REASON
FROM V2RETAIL.ARS_BRONZE.ARS_LISTING_HISTORY lh
LEFT JOIN V2RETAIL.ARS_BRONZE.STORE_PLANT_MASTER sp
       ON sp.ST_CD = lh.WERKS
LEFT JOIN V2RETAIL.ARS_BRONZE.MASTER_PRODUCT mp
       ON mp.GEN_ART_NUMBER = lh.GEN_ART_NUMBER;

-- ---------------------------------------------------------------------------
-- V_SILVER_ALLOC — source has MAJ_CAT + attrs directly; minimal joins
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_SILVER_ALLOC AS
SELECT
    ah.SESSION_ID,
    CAST(TO_TIMESTAMP_NTZ(s.STARTED_AT, 9) AS DATE)  AS RUN_DATE,
    ah.PARK_STATUS,
    ah.WERKS,
    ah.GEN_ART_NUMBER,
    ah.GEN_ART_DESC,
    ah.VAR_ART,
    ah.SZ,
    ah.MAJ_CAT,
    ah.CLR,
    ah.FAB,
    ah.FIT,
    ah.RNG_SEG,
    ah.MERGE_RNG_SEG,
    ah.M_VND_CD,
    ah.M_YARN_02,
    ah.WEAVE_2,
    ah.MRP,
    CAST(NULL AS STRING)                              AS SSN,
    ah.ALLOC_FLAG,
    ah.SHIP_QTY,
    ah.HOLD_QTY,
    ah.ALLOC_QTY,
    ah.ALLOC_WAVE,
    ah.ALLOC_ROUND,
    ah.ALLOC_STATUS,
    ah.ALLOC_SEQ,
    ah.ALLOC_PHASE,
    CAST(ah.ALLOC_REASON AS STRING)                   AS ALLOC_REASON,
    ah.ALLOC_REMARKS,
    ah.FROM_HOLD_QTY,
    ah.SKIP_REASON
FROM V2RETAIL.ARS_BRONZE.ARS_ALLOC_HISTORY ah
LEFT JOIN V2RETAIL.ARS_BRONZE.ARS_LISTING_SESSIONS s
       ON s.SESSION_ID = ah.SESSION_ID;

-- ---------------------------------------------------------------------------
-- V_SILVER_REQUIREMENT — source table empty; placeholder NULL view
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_SILVER_REQUIREMENT AS
SELECT
    CAST(NULL AS STRING)  AS WERKS,
    CAST(NULL AS STRING)  AS MAJ_CAT,
    CAST(NULL AS NUMBER)  AS GEN_ART_COUNT,
    CAST(NULL AS NUMBER)  AS LISTING_CNT,
    CAST(NULL AS NUMBER)  AS I_ROD_CNT,
    CAST(NULL AS NUMBER)  AS FOCUS_W_CAP_CNT,
    CAST(NULL AS NUMBER)  AS FOCUS_WO_CAP_CNT,
    CAST(NULL AS NUMBER)  AS CORE_CNT,
    CAST(NULL AS NUMBER)  AS AUTO_CNT,
    CAST(NULL AS NUMBER)  AS HH_ART_CNT,
    CAST(NULL AS FLOAT)   AS AVG_MANUAL_DENSITY,
    CAST(NULL AS TIMESTAMP_NTZ) AS LAST_UPLOAD_AT
WHERE 1=0;

-- ---------------------------------------------------------------------------
-- V_SILVER_PEND_ALC
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_SILVER_PEND_ALC AS
SELECT
    p.RDC,
    p.ST_CD,
    p.ST_CD                                          AS WERKS,
    p.MATNR,
    p.QTY,
    p.SESSION_ID,
    p.ARTICLE_NUMBER,
    p.MAJ_CAT,
    p.GEN_ART_NUMBER,
    p.CLR,
    p.ALLOC_MODE,
    p.SOURCE,
    p.ALLOC_QTY,
    p.BDC_QTY,
    p.DO_QTY,
    TO_TIMESTAMP_NTZ(p.APPROVED_AT, 9)               AS APPROVED_AT,
    TO_TIMESTAMP_NTZ(p.LAST_BDC_AT, 9)               AS LAST_BDC_AT,
    p.DO_NUMBER,
    TO_TIMESTAMP_NTZ(p.DO_UPLOADED_AT, 9)            AS DO_UPLOADED_AT,
    TO_TIMESTAMP_NTZ(p.LAST_DO_AT, 9)                AS LAST_DO_AT,
    p.IS_CLOSED,
    CAST(p.REMARKS AS STRING)                        AS REMARKS,
    p.PEND_QTY,
    p.ID
FROM V2RETAIL.ARS_BRONZE.ARS_PEND_ALC p;

-- ---------------------------------------------------------------------------
-- V_SILVER_DC_STOCK
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_SILVER_DC_STOCK AS
SELECT
    m.RDC,
    m.GEN_ART_NUMBER,
    ANY_VALUE(m.MAJ_CAT)                             AS MAJ_CAT,
    ANY_VALUE(m.GEN_ART_DESC)                        AS GEN_ART_DESC,
    ANY_VALUE(m.CLR)                                 AS CLR,
    ANY_VALUE(m.MRP)                                 AS MRP,
    ANY_VALUE(m.SSN)                                 AS SSN,
    COUNT(DISTINCT m.ARTICLE_NUMBER)                 AS VAR_ART_COUNT,
    COUNT(DISTINCT m.SZ)                             AS SIZE_COUNT,
    SUM(COALESCE(m.STK_QTY, 0))                      AS STK_QTY_TOTAL,
    SUM(COALESCE(m.HOLD_QTY, 0))                     AS HOLD_QTY_TOTAL,
    SUM(COALESCE(m.PEND_QTY, 0))                     AS PEND_QTY_TOTAL,
    SUM(COALESCE(m.ARS_PEND, 0))                     AS ARS_PEND_TOTAL,
    SUM(COALESCE(m.FNL_Q, 0))                        AS FNL_Q_TOTAL,
    MAX(m."DATE")                                    AS SNAPSHOT_DATE
FROM V2RETAIL.ARS_BRONZE.ARS_MSA_VAR_ART m
GROUP BY m.RDC, m.GEN_ART_NUMBER;

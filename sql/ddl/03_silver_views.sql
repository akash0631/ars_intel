-- ars_intel: silver views in ARS_GOLD
-- Typed, joined, enriched. No rule logic here — just clean slabs.
-- NOTE: pandas write_pandas serializes datetime64[ns] as NUMBER scale=9 (epoch ns).
-- We unwrap via TO_TIMESTAMP_NTZ(col, 9) in this layer.

USE SCHEMA V2RETAIL.ARS_GOLD;

-- ---------------------------------------------------------------------------
-- V_SILVER_SESSIONS
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_SILVER_SESSIONS AS
SELECT
    s.SESSION_ID,
    TO_TIMESTAMP_NTZ(s.STARTED_AT, 9)               AS STARTED_AT,
    CAST(NULL AS TIMESTAMP_NTZ)                     AS FINISHED_AT,
    CAST(TO_TIMESTAMP_NTZ(s.STARTED_AT, 9) AS DATE) AS RUN_DATE,
    HOUR(TO_TIMESTAMP_NTZ(s.STARTED_AT, 9))         AS RUN_HOUR,
    s.STATUS,
    s.ALLOCATION_MODE,
    s.MAJCAT_COUNT,
    s.ALLOC_ROWS,
    s.SHIP_QTY_TOTAL,
    s.HOLD_QTY_TOTAL,
    s.FAILED_MAJCATS,
    s.PARKED_STATUS
FROM V2RETAIL.ARS_BRONZE.ARS_LISTING_SESSIONS s;

-- ---------------------------------------------------------------------------
-- V_SILVER_SESSION_MAJCAT
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_SILVER_SESSION_MAJCAT AS
SELECT
    s.SESSION_ID,
    TO_TIMESTAMP_NTZ(s.STARTED_AT, 9)               AS STARTED_AT,
    CAST(TO_TIMESTAMP_NTZ(s.STARTED_AT, 9) AS DATE) AS RUN_DATE,
    HOUR(TO_TIMESTAMP_NTZ(s.STARTED_AT, 9))         AS RUN_HOUR,
    s.STATUS                                        AS SESSION_STATUS,
    s.ALLOCATION_MODE,
    q.MAJ_CAT,
    q.STATUS                                        AS MAJCAT_STATUS,
    q.ERROR_MSG                                     AS MAJCAT_ERROR_MSG,
    q.SHIP_QTY                                      AS MAJCAT_SHIP_QTY,
    q.HOLD_QTY                                      AS MAJCAT_HOLD_QTY,
    q.ROWS_AFFECTED                                 AS MAJCAT_ROWS_AFFECTED,
    q.ATTEMPTS                                      AS MAJCAT_ATTEMPTS,
    q.DURATION_SEC                                  AS MAJCAT_DURATION_SEC,
    q.OPT_COUNT                                     AS MAJCAT_OPT_COUNT,
    TO_TIMESTAMP_NTZ(q.PICKED_AT, 9)                AS MAJCAT_PICKED_AT,
    TO_TIMESTAMP_NTZ(q.COMPLETED_AT, 9)             AS MAJCAT_COMPLETED_AT,
    q.WORKER_ID                                     AS MAJCAT_WORKER_ID
FROM V2RETAIL.ARS_BRONZE.ARS_LISTING_SESSIONS s
LEFT JOIN V2RETAIL.ARS_BRONZE.ARS_ALLOC_MAJCAT_QUEUE q
       ON TO_TIMESTAMP_NTZ(q.CREATED_AT, 9)
          BETWEEN DATEADD('hour', -1, TO_TIMESTAMP_NTZ(s.STARTED_AT, 9))
              AND DATEADD('hour',  6, TO_TIMESTAMP_NTZ(s.STARTED_AT, 9));

-- ---------------------------------------------------------------------------
-- V_SILVER_LISTING
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_SILVER_LISTING AS
SELECT
    lh.SESSION_ID,
    TO_TIMESTAMP_NTZ(lh.PARKED_AT, 9)               AS PARKED_AT,
    TO_TIMESTAMP_NTZ(lh.APPROVED_AT, 9)             AS APPROVED_AT,
    lh.APPROVED_BY,
    lh.WERKS,
    COALESCE(sp.STORE_NAME, lh.WERKS)               AS STORE_NAME,
    COALESCE(sp.RDC, lh.RDC)                        AS RDC,
    COALESCE(sp.RANK, lh.ST_RANK)                   AS ST_RANK,
    GREATEST(
        0.05,
        LEAST(1.0, 1.0 - (COALESCE(sp.RANK, lh.ST_RANK, 20) - 1) * 0.05)
    )                                               AS STORE_PRIORITY,
    lh.MAJ_CAT,
    lh.GEN_ART_NUMBER,
    COALESCE(mp.MAJ_CAT, lh.MAJ_CAT)                AS MAJ_CAT_CANON,
    COALESCE(mp.CLR, lh.CLR)                        AS CLR,
    COALESCE(mp.FAB, lh.FAB)                        AS FAB,
    mp.FIT                                          AS FIT,
    COALESCE(mp.RNG_SEG, lh.RNG_SEG)                AS RNG_SEG,
    COALESCE(mp.MERGE_RNG_SEG, lh.MERGE_RNG_SEG)    AS MERGE_RNG_SEG,
    COALESCE(mp.M_VND_CD, lh.M_VND_CD)              AS M_VND_CD,
    COALESCE(mp.M_YARN_02, lh.M_YARN_02)            AS M_YARN_02,
    COALESCE(mp.WEAVE_2, lh.WEAVE_2)                AS WEAVE_2,
    COALESCE(mp.GEN_ART_DESC, lh.GEN_ART_DESC)      AS GEN_ART_DESC,
    mp.MRP                                          AS MRP,
    mp.SSN                                          AS SSN,
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
    lh.PER_OPT_SALE, lh.OPT_MBQ, lh.OPT_REQ, lh.EXCESS_STK, lh.ART_EXCESS
FROM V2RETAIL.ARS_BRONZE.ARS_LISTING_HISTORY lh
LEFT JOIN V2RETAIL.ARS_BRONZE.STORE_PLANT_MASTER sp
       ON sp.PLANT_CODE = lh.WERKS
LEFT JOIN V2RETAIL.ARS_BRONZE.MASTER_PRODUCT mp
       ON mp.GEN_ART_NUMBER = lh.GEN_ART_NUMBER;

-- ---------------------------------------------------------------------------
-- V_SILVER_LISTING_ELIG: separate view appending ELIG_FLAG/ELIG_REASON only when
-- those cols exist (some loads of ARS_LISTING_HISTORY omit them; defensive).
-- ELIG_REASON inference: NULL ELIG → NO_DEMAND.
-- ---------------------------------------------------------------------------
-- (left for follow-up — ARS_LISTING_HISTORY in this load omits ELIG_FLAG/REASON)

-- ---------------------------------------------------------------------------
-- V_SILVER_ALLOC
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_SILVER_ALLOC AS
SELECT
    ah.SESSION_ID,
    CAST(TO_TIMESTAMP_NTZ(s.STARTED_AT, 9) AS DATE) AS RUN_DATE,
    ah.PARK_STATUS,
    ah.WERKS,
    ah.GEN_ART_NUMBER,
    ah.GEN_ART_DESC,
    ah.VAR_ART,
    mp.SZ,
    mp.MAJ_CAT,
    mp.CLR,
    mp.FAB,
    mp.FIT,
    mp.RNG_SEG,
    mp.MERGE_RNG_SEG,
    mp.M_VND_CD,
    mp.M_YARN_02,
    mp.WEAVE_2,
    mp.MRP,
    mp.SSN,
    ah.ALLOC_FLAG,
    ah.SHIP_QTY,
    ah.HOLD_QTY,
    ah.ALLOC_QTY,
    ah.ALLOC_WAVE,
    ah.ALLOC_ROUND,
    ah.ALLOC_STATUS,
    ah.ALLOC_SEQ,
    ah.ALLOC_PHASE,
    ah.ALLOC_REASON,
    ah.ALLOC_REMARKS,
    ah.FROM_HOLD_QTY
FROM V2RETAIL.ARS_BRONZE.ARS_ALLOC_HISTORY ah
LEFT JOIN V2RETAIL.ARS_BRONZE.MASTER_PRODUCT mp
       ON mp.ARTICLE_NUMBER = ah.VAR_ART
LEFT JOIN V2RETAIL.ARS_BRONZE.ARS_LISTING_SESSIONS s
       ON s.SESSION_ID = ah.SESSION_ID;

-- ---------------------------------------------------------------------------
-- V_SILVER_REQUIREMENT
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_SILVER_REQUIREMENT AS
SELECT
    r.ST_CD                                         AS WERKS,
    r.MAJ_CAT,
    COUNT(*)                                        AS GEN_ART_COUNT,
    SUM(COALESCE(r.LISTING, 0))                     AS LISTING_CNT,
    SUM(COALESCE(r.I_ROD, 0))                       AS I_ROD_CNT,
    SUM(COALESCE(r.FOCUS_W_CAP, 0))                 AS FOCUS_W_CAP_CNT,
    SUM(COALESCE(r.FOCUS_WO_CAP, 0))                AS FOCUS_WO_CAP_CNT,
    SUM(COALESCE(r.CORE, 0))                        AS CORE_CNT,
    SUM(COALESCE(r.AUTO, 0))                        AS AUTO_CNT,
    SUM(COALESCE(r.HH_ART, 0))                      AS HH_ART_CNT,
    AVG(r.MANUAL_DENSITY)                           AS AVG_MANUAL_DENSITY,
    MAX(r.UPLOAD_DATETIME)                          AS LAST_UPLOAD_AT
FROM V2RETAIL.ARS_BRONZE.MASTER_ALC_INPUT_ST_ART r
GROUP BY r.ST_CD, r.MAJ_CAT;

-- ---------------------------------------------------------------------------
-- V_SILVER_PEND_ALC
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_SILVER_PEND_ALC AS
SELECT
    p.RDC,
    p.ST_CD,
    p.ST_CD                                         AS WERKS,
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
    TO_TIMESTAMP_NTZ(p.APPROVED_AT, 9)              AS APPROVED_AT,
    TO_TIMESTAMP_NTZ(p.LAST_BDC_AT, 9)              AS LAST_BDC_AT,
    p.DO_NUMBER,
    TO_TIMESTAMP_NTZ(p.DO_UPLOADED_AT, 9)           AS DO_UPLOADED_AT,
    TO_TIMESTAMP_NTZ(p.LAST_DO_AT, 9)               AS LAST_DO_AT,
    p.IS_CLOSED,
    p.REMARKS,
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
    ANY_VALUE(m.MAJ_CAT)                            AS MAJ_CAT,
    ANY_VALUE(m.GEN_ART_DESC)                       AS GEN_ART_DESC,
    ANY_VALUE(m.CLR)                                AS CLR,
    ANY_VALUE(m.MRP)                                AS MRP,
    ANY_VALUE(m.SSN)                                AS SSN,
    COUNT(DISTINCT m.ARTICLE_NUMBER)                AS VAR_ART_COUNT,
    COUNT(DISTINCT m.SZ)                            AS SIZE_COUNT,
    SUM(COALESCE(m.STK_QTY, 0))                     AS STK_QTY_TOTAL,
    SUM(COALESCE(m.HOLD_QTY, 0))                    AS HOLD_QTY_TOTAL,
    SUM(COALESCE(m.PEND_QTY, 0))                    AS PEND_QTY_TOTAL,
    SUM(COALESCE(m.ARS_PEND, 0))                    AS ARS_PEND_TOTAL,
    SUM(COALESCE(m.FNL_Q, 0))                       AS FNL_Q_TOTAL,
    MAX(m."DATE")                                   AS SNAPSHOT_DATE
FROM V2RETAIL.ARS_BRONZE.ARS_MSA_VAR_ART m
GROUP BY m.RDC, m.GEN_ART_NUMBER;

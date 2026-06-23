-- ars_intel: bronze table definitions
-- Mirror of arsdbpro/Rep_Data. Column names + types match source where practical.
-- Every table carries _LOADED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP.

USE SCHEMA V2RETAIL.ARS_BRONZE;

-- ---------------------------------------------------------------------------
-- ARS_LISTING_SESSIONS: one row per ARS engine run
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ARS_LISTING_SESSIONS (
    SESSION_ID          VARCHAR     NOT NULL,
    STARTED_AT          TIMESTAMP_NTZ,
    STATUS              VARCHAR,            -- SUCCESS | FAILED | CANCELLED
    ALLOCATION_MODE     VARCHAR,
    MAJCAT_COUNT        NUMBER,
    ALLOC_ROWS          NUMBER,
    SHIP_QTY_TOTAL      FLOAT,
    HOLD_QTY_TOTAL      FLOAT,
    FAILED_MAJCATS      VARCHAR,
    PARKED_STATUS       VARCHAR,
    _LOADED_AT          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT PK_ARS_LISTING_SESSIONS PRIMARY KEY (SESSION_ID)
);

-- ---------------------------------------------------------------------------
-- ARS_LISTING_HISTORY: ~22M rows, store-gen_art level per session
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ARS_LISTING_HISTORY (
    SESSION_ID              VARCHAR,
    PARKED_AT               TIMESTAMP_NTZ,
    APPROVED_AT             TIMESTAMP_NTZ,
    APPROVED_BY             VARCHAR,
    WERKS                   VARCHAR,
    RDC                     VARCHAR,
    MAJ_CAT                 VARCHAR,
    GEN_ART_NUMBER          NUMBER,
    CLR                     VARCHAR,
    GEN_ART_DESC            VARCHAR,
    WEAVE_2                 VARCHAR,
    M_VND_CD                VARCHAR,
    M_YARN_02               VARCHAR,
    RNG_SEG                 VARCHAR,
    FAB                     VARCHAR,
    FIT                     VARCHAR,
    MERGE_RNG_SEG           VARCHAR,
    MRP                     FLOAT,
    SSN                     VARCHAR,
    IS_NEW                  NUMBER,
    OPT_TYPE                VARCHAR,
    ST_RANK                 NUMBER,
    ST_STK_V06_QTY          FLOAT,
    ST_STK_V07_QTY          FLOAT,
    STK_TTL                 FLOAT,
    STR                     FLOAT,
    AUTO_GEN_ART_SALE       FLOAT,
    AGE                     NUMBER,
    FOCUS_W_CAP             NUMBER,
    FOCUS_WO_CAP            NUMBER,
    I_ROD                   NUMBER,
    LISTING                 NUMBER,
    RL_HOLD_QTY             FLOAT,
    MSA_FNL_Q               FLOAT,
    VAR_COUNT               NUMBER,
    VAR_FNL_COUNT           NUMBER,
    -- maj_cat rollups
    MJ_STK_TTL              FLOAT,
    MJ_STR                  FLOAT,
    MJ_CONT                 FLOAT,
    MJ_MBQ                  FLOAT,
    MJ_OPT_CNT              NUMBER,
    MJ_DISP_Q               FLOAT,
    MJ_REQ                  FLOAT,
    MJ_REQ_WITH_EXC         FLOAT,
    MJ_REQ_NO_EXC           FLOAT,
    -- merge_rng_seg rollups
    MERGE_RNG_SEG_STK_TTL   FLOAT,
    MERGE_RNG_SEG_STR       FLOAT,
    MERGE_RNG_SEG_CONT      FLOAT,
    MERGE_RNG_SEG_MBQ       FLOAT,
    MERGE_RNG_SEG_OPT_CNT   NUMBER,
    MERGE_RNG_SEG_DISP_Q    FLOAT,
    MERGE_RNG_SEG_REQ       FLOAT,
    -- rng_seg rollups
    RNG_SEG_STK_TTL         FLOAT,
    RNG_SEG_STR             FLOAT,
    RNG_SEG_CONT            FLOAT,
    RNG_SEG_MBQ             FLOAT,
    RNG_SEG_OPT_CNT         NUMBER,
    RNG_SEG_DISP_Q          FLOAT,
    RNG_SEG_REQ             FLOAT,
    -- m_yarn_02 rollups
    M_YARN_02_STK_TTL       FLOAT,
    M_YARN_02_STR           FLOAT,
    M_YARN_02_CONT          FLOAT,
    M_YARN_02_MBQ           FLOAT,
    M_YARN_02_OPT_CNT       NUMBER,
    M_YARN_02_DISP_Q        FLOAT,
    M_YARN_02_REQ           FLOAT,
    -- weave_2 rollups
    WEAVE_2_STK_TTL         FLOAT,
    WEAVE_2_STR             FLOAT,
    WEAVE_2_CONT            FLOAT,
    WEAVE_2_MBQ             FLOAT,
    WEAVE_2_OPT_CNT         NUMBER,
    WEAVE_2_DISP_Q          FLOAT,
    WEAVE_2_REQ             FLOAT,
    -- fab rollups
    FAB_STK_TTL             FLOAT,
    FAB_STR                 FLOAT,
    FAB_CONT                FLOAT,
    FAB_MBQ                 FLOAT,
    FAB_OPT_CNT             NUMBER,
    FAB_DISP_Q              FLOAT,
    FAB_REQ                 FLOAT,
    -- clr rollups
    CLR_STK_TTL             FLOAT,
    CLR_STR                 FLOAT,
    CLR_CONT                FLOAT,
    CLR_MBQ                 FLOAT,
    CLR_OPT_CNT             NUMBER,
    CLR_DISP_Q              FLOAT,
    CLR_REQ                 FLOAT,
    -- m_vnd_cd rollups
    M_VND_CD_STK_TTL        FLOAT,
    M_VND_CD_STR            FLOAT,
    M_VND_CD_CONT           FLOAT,
    M_VND_CD_MBQ            FLOAT,
    M_VND_CD_OPT_CNT        NUMBER,
    M_VND_CD_DISP_Q         FLOAT,
    M_VND_CD_REQ            FLOAT,
    -- fit rollups
    FIT_STK_TTL             FLOAT,
    FIT_STR                 FLOAT,
    FIT_CONT                FLOAT,
    FIT_MBQ                 FLOAT,
    FIT_OPT_CNT             NUMBER,
    FIT_DISP_Q              FLOAT,
    FIT_REQ                 FLOAT,
    -- option-level outputs
    PER_OPT_SALE            FLOAT,
    OPT_MBQ                 FLOAT,
    OPT_REQ                 FLOAT,
    EXCESS_STK              FLOAT,
    ART_EXCESS              FLOAT,
    ELIG_FLAG               NUMBER,         -- 1=OK, 0=blocked
    ELIG_REASON             VARCHAR,        -- OK | NO_DISPLAY | NO_DEMAND | NOT_LISTED | NO_STOCK
    _LOADED_AT              TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP
)
CLUSTER BY (SESSION_ID, WERKS);

-- ---------------------------------------------------------------------------
-- ARS_ALLOC_HISTORY: ~11.6M rows, store-var_art level allocation output
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ARS_ALLOC_HISTORY (
    SESSION_ID      VARCHAR,
    PARK_STATUS     VARCHAR,
    WERKS           VARCHAR,
    GEN_ART_NUMBER  NUMBER,
    GEN_ART_DESC    VARCHAR,
    VAR_ART         VARCHAR,
    ALLOC_FLAG      NUMBER,
    SHIP_QTY        FLOAT,
    HOLD_QTY        FLOAT,
    ALLOC_QTY       FLOAT,
    ALLOC_WAVE      VARCHAR,
    ALLOC_ROUND     NUMBER,
    ALLOC_STATUS    VARCHAR,            -- ALLOCATED | PARTIAL | SKIPPED
    ALLOC_SEQ       NUMBER,
    ALLOC_PHASE     VARCHAR,
    ALLOC_REASON    VARCHAR,            -- KNOWN GAP: always NULL today
    ALLOC_REMARKS   VARCHAR,
    FROM_HOLD_QTY   FLOAT,
    _LOADED_AT      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP
)
CLUSTER BY (SESSION_ID, WERKS);

-- ---------------------------------------------------------------------------
-- ARS_ALLOC_MAJCAT_QUEUE: worker queue, one row per maj_cat per session
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ARS_ALLOC_MAJCAT_QUEUE (
    BATCH_ID        VARCHAR,
    MAJ_CAT         VARCHAR,
    OPT_COUNT       NUMBER,
    STATUS          VARCHAR,            -- DONE | FAILED | PENDING | RUNNING
    WORKER_ID       VARCHAR,
    ATTEMPTS        NUMBER,
    PICKED_AT       TIMESTAMP_NTZ,
    COMPLETED_AT    TIMESTAMP_NTZ,
    SHIP_QTY        FLOAT,
    HOLD_QTY        FLOAT,
    ROWS_AFFECTED   NUMBER,
    DURATION_SEC    FLOAT,
    ERROR_MSG       VARCHAR,
    ALLOCATION_MODE VARCHAR,
    CREATED_AT      TIMESTAMP_NTZ,
    _LOADED_AT      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP
);

-- ---------------------------------------------------------------------------
-- ARS_PEND_ALC: pending allocation queue (~1.1M)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ARS_PEND_ALC (
    ID              NUMBER,
    RDC             VARCHAR,
    ST_CD           VARCHAR,
    MATNR           NUMBER,             -- bigint
    QTY             NUMBER,
    SESSION_ID      VARCHAR,
    ARTICLE_NUMBER  VARCHAR,
    MAJ_CAT         VARCHAR,
    GEN_ART_NUMBER  NUMBER,
    CLR             VARCHAR,
    ALLOC_MODE      VARCHAR,
    SOURCE          VARCHAR,
    ALLOC_QTY       FLOAT,
    BDC_QTY         FLOAT,              -- KNOWN GAP: 0 across 7d
    DO_QTY          FLOAT,
    APPROVED_AT     TIMESTAMP_NTZ,
    LAST_BDC_AT     TIMESTAMP_NTZ,
    DO_NUMBER       VARCHAR,
    DO_UPLOADED_AT  TIMESTAMP_NTZ,
    LAST_DO_AT      TIMESTAMP_NTZ,
    IS_CLOSED       NUMBER,             -- bit
    REMARKS         VARCHAR,
    PEND_QTY        FLOAT,
    _LOADED_AT      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP
)
CLUSTER BY (SESSION_ID, ST_CD);

-- ---------------------------------------------------------------------------
-- ARS_PEND_ALC_OPERATIONS: audit log of approve/do/bdc/manual/adhoc_close
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ARS_PEND_ALC_OPERATIONS (
    OP_ID           NUMBER,
    OP_TYPE         VARCHAR,            -- APPROVE | DO | BDC | MANUAL | ADHOC_CLOSE
    OP_KEY          VARCHAR,
    OP_DATE         TIMESTAMP_NTZ,
    CREATED_BY      VARCHAR,
    SUMMARY         VARCHAR,
    ROWS_AFFECTED   NUMBER,
    QTY_TOTAL       FLOAT,
    PAYLOAD         VARIANT,
    REVERTED_AT     TIMESTAMP_NTZ,
    REVERTED_BY     VARCHAR,
    _LOADED_AT      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP
);

-- ---------------------------------------------------------------------------
-- ARS_MSA_VAR_ART: size-level DC stock & demand snapshot
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ARS_MSA_VAR_ART (
    MAJ_CAT         VARCHAR,
    V02_FRESH       FLOAT,
    LIST            NUMBER,
    AVG_DENSITY     FLOAT,
    MC_DESC         VARCHAR,
    MICRO_MVGR      VARCHAR,
    PEND_QTY        FLOAT,
    M_VND_CD        VARCHAR,
    SZ              VARCHAR,
    SUB_DIV         VARCHAR,
    GEN_ART_NUMBER  NUMBER,
    MACRO_MVGR      VARCHAR,
    DIV             VARCHAR,
    GEN_ART_DESC    VARCHAR,
    ARTICLE_NUMBER  VARCHAR,
    SEG             VARCHAR,
    "DATE"          DATE,
    CLR             VARCHAR,
    PAK_SZ          NUMBER,
    RNG_SEG         VARCHAR,
    FNL_Q           FLOAT,
    FAB             VARCHAR,
    MRP             FLOAT,
    SSN             VARCHAR,
    STK_QTY         FLOAT,
    RDC             VARCHAR,
    HOLD_QTY        FLOAT,
    ARS_PEND        FLOAT,
    _LOADED_AT      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP
)
CLUSTER BY (RDC, GEN_ART_NUMBER);

-- ---------------------------------------------------------------------------
-- MASTER_ALC_INPUT_ST_ART: per-store-article requirement input
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS MASTER_ALC_INPUT_ST_ART (
    ST_CD               VARCHAR,
    MAJ_CAT             VARCHAR,
    "10_DIGIT"          NUMBER,         -- bigint, gen_art
    CLR                 VARCHAR,
    LISTING             NUMBER,
    I_ROD               NUMBER,
    FOCUS_W_CAP         NUMBER,
    FOCUS_WO_CAP        NUMBER,
    MANUAL_DENSITY      FLOAT,
    CORE                NUMBER,
    AUTO                NUMBER,
    HH_ART              NUMBER,
    UPLOAD_DATETIME     TIMESTAMP_NTZ,
    _LOADED_AT          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP
);

-- ---------------------------------------------------------------------------
-- Master contribution tables (each = MAJ_CAT + ATTR + CONT_PCT)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS MASTER_CONT_RNG_SEG (
    MAJ_CAT     VARCHAR,
    RNG_SEG     VARCHAR,
    CONT_PCT    FLOAT,
    _LOADED_AT  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS MASTER_CONT_FAB (
    MAJ_CAT     VARCHAR,
    FAB         VARCHAR,
    CONT_PCT    FLOAT,
    _LOADED_AT  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS MASTER_CONT_CLR (
    MAJ_CAT     VARCHAR,
    CLR         VARCHAR,
    CONT_PCT    FLOAT,
    _LOADED_AT  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS MASTER_CONT_FIT (
    MAJ_CAT     VARCHAR,
    FIT         VARCHAR,
    CONT_PCT    FLOAT,
    _LOADED_AT  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS MASTER_CONT_M_VND_CD (
    MAJ_CAT     VARCHAR,
    M_VND_CD    VARCHAR,
    CONT_PCT    FLOAT,
    _LOADED_AT  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS MASTER_CONT_M_YARN_02 (
    MAJ_CAT     VARCHAR,
    M_YARN_02   VARCHAR,
    CONT_PCT    FLOAT,
    _LOADED_AT  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS MASTER_CONT_WEAVE_2 (
    MAJ_CAT     VARCHAR,
    WEAVE_2     VARCHAR,
    CONT_PCT    FLOAT,
    _LOADED_AT  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS MASTER_CONT_SZ (
    MAJ_CAT     VARCHAR,
    SZ          VARCHAR,
    CONT_PCT    FLOAT,
    _LOADED_AT  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS MASTER_CONT_MERGE_RNG_SEG (
    MAJ_CAT         VARCHAR,
    MERGE_RNG_SEG   VARCHAR,
    CONT_PCT        FLOAT,
    _LOADED_AT      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP
);

-- ---------------------------------------------------------------------------
-- Reference masters
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS STORE_PLANT_MASTER (
    PLANT_CODE  VARCHAR,
    STORE_NAME  VARCHAR,
    RDC         VARCHAR,
    RANK        NUMBER,
    _LOADED_AT  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS MASTER_PRODUCT (
    GEN_ART_NUMBER  NUMBER,
    ARTICLE_NUMBER  VARCHAR,
    MAJ_CAT         VARCHAR,
    CLR             VARCHAR,
    FAB             VARCHAR,
    FIT             VARCHAR,
    RNG_SEG         VARCHAR,
    MERGE_RNG_SEG   VARCHAR,
    M_VND_CD        VARCHAR,
    M_YARN_02       VARCHAR,
    WEAVE_2         VARCHAR,
    SZ              VARCHAR,
    GEN_ART_DESC    VARCHAR,
    MRP             FLOAT,
    SSN             VARCHAR,
    _LOADED_AT      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP
);

-- ---------------------------------------------------------------------------
-- ET_SALES_DATA: store-matnr-day sales (used for L-7d size mix)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ET_SALES_DATA (
    WERKS       VARCHAR,
    MATNR       VARCHAR,
    "DATE"      DATE,
    QTY         FLOAT,
    _LOADED_AT  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP
)
CLUSTER BY ("DATE", WERKS);

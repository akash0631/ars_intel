-- ars_intel: alert mart
-- Populated by 9 rule SQL views (built separately). One row per detected gap.

USE SCHEMA V2RETAIL.ARS_GOLD;

CREATE TABLE IF NOT EXISTS MART_ALERTS (
    ALERT_ID        NUMBER          AUTOINCREMENT,
    RULE_ID         VARCHAR         NOT NULL,        -- e.g. R01_NO_DISPLAY, R02_NO_DEMAND...
    SESSION_ID      VARCHAR,
    RUN_DATE        DATE,
    STORE           VARCHAR,
    MAJ_CAT         VARCHAR,
    GEN_ART_NUMBER  NUMBER,
    VAR_ART         VARCHAR,
    ATTR_DIM        VARCHAR,                          -- e.g. CLR, FAB, FIT, SZ
    ATTR_VAL        VARCHAR,                          -- e.g. BLU, COTTON, SLIM, 32
    LOST_QTY        FLOAT,                            -- quantified gap (units or rupees)
    ROOT_CAUSE      VARCHAR,                          -- inferred reason (since ALLOC_REASON is NULL)
    FIX_ACTION      VARCHAR,                          -- recommended action
    SEVERITY        FLOAT,                            -- 0.0..1.0 priority score
    DETAIL_JSON     VARIANT,                          -- rule-specific payload
    CREATED_AT      TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT PK_MART_ALERTS PRIMARY KEY (ALERT_ID)
)
CLUSTER BY (RUN_DATE, RULE_ID);

-- ars_intel: schemas + watermark table
-- Target: Snowflake account iafphkw-hh80816, db V2RETAIL, warehouse ALLOC_WH

USE DATABASE V2RETAIL;

CREATE SCHEMA IF NOT EXISTS V2RETAIL.ARS_BRONZE
    COMMENT = 'Raw mirror of arsdbpro/Rep_Data (SQL Server, HOPC345). 1:1 copy, no transforms.';

CREATE SCHEMA IF NOT EXISTS V2RETAIL.ARS_GOLD
    COMMENT = 'Typed silver views + MART_ALERTS + replication control.';

-- Replication control table -------------------------------------------------
CREATE TABLE IF NOT EXISTS V2RETAIL.ARS_GOLD.REPLICATION_WATERMARKS (
    TABLE_NAME      VARCHAR     NOT NULL,
    LAST_LOADED_AT  TIMESTAMP_NTZ,
    ROWS_LOADED     NUMBER,
    CONSTRAINT PK_REPLICATION_WATERMARKS PRIMARY KEY (TABLE_NAME)
)
COMMENT = 'One row per bronze table. Updated after each incremental load.';

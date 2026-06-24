-- ============================================================================
-- MART_ALERTS_TOP
-- ----------------------------------------------------------------------------
-- View of top alerts from MART_ALERTS for the current run_date window,
-- enriched with store and product master data. Used by the alerts UI / digest.
--
-- Source : V2RETAIL.ARS_GOLD.MART_ALERTS
-- Joins  : STORE_PLANT_MASTER (store name), MASTER_PRODUCT (article desc)
-- Output : One row per alert with severity rank + bucket + recency.
-- ============================================================================

CREATE OR REPLACE VIEW V2RETAIL.ARS_GOLD.MART_ALERTS_TOP AS
WITH current_window AS (
    -- Latest run_date present in MART_ALERTS (alerts mart is rebuilt per run).
    SELECT MAX(RUN_DATE) AS max_run_date
    FROM V2RETAIL.ARS_GOLD.MART_ALERTS
),
scoped AS (
    SELECT a.*
    FROM V2RETAIL.ARS_GOLD.MART_ALERTS a
    CROSS JOIN current_window cw
    WHERE a.RUN_DATE >= DATEADD(day, -1, cw.max_run_date)
      AND a.RUN_DATE <= cw.max_run_date
),
enriched AS (
    SELECT
        s.*,
        spm.ST_NM                        AS STORE_NAME,
        spm.ZONE                         AS STORE_ZONE,
        spm.STATE                        AS STORE_STATE,
        mp.GEN_ART_DESC,
        mp.MAJ_CAT                       AS PROD_MAJ_CAT,
        mp.MRP                           AS PROD_MRP,
        mp.SSN                           AS PROD_SSN,
        DATEDIFF(day, s.RUN_DATE, CURRENT_DATE()) AS DAYS_SINCE
    FROM scoped s
    LEFT JOIN V2RETAIL.ARS_BRONZE.STORE_PLANT_MASTER spm
        ON spm.ST_CD = s.STORE
    LEFT JOIN V2RETAIL.ARS_BRONZE.MASTER_PRODUCT mp
        ON mp.GEN_ART_NUMBER = s.GEN_ART_NUMBER
)
SELECT
    e.*,
    ROW_NUMBER() OVER (ORDER BY e.SEVERITY DESC, e.RUN_DATE DESC) AS SEVERITY_RANK,
    CASE
        WHEN e.SEVERITY > 5000 THEN 'CRITICAL'
        WHEN e.SEVERITY > 1000 THEN 'HIGH'
        WHEN e.SEVERITY > 100  THEN 'MEDIUM'
        ELSE 'LOW'
    END AS SEVERITY_BUCKET
FROM enriched e
ORDER BY e.SEVERITY DESC;

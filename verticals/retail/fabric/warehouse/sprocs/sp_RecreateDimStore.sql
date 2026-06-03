-- Builds dbo.dim_store by CTAS from the curated lakehouse shortcut.
CREATE OR ALTER PROCEDURE dbo.sp_RecreateDimStore
AS
BEGIN
    DROP TABLE IF EXISTS dbo.dim_store;
    -- Dynamic SQL so column binding is deferred until execute time. At
    -- sproc-create time the silver_curated.store shortcut may not exist yet
    -- (silver notebooks haven't run on a fresh deploy).
    EXEC ('
        CREATE TABLE dbo.dim_store AS
        SELECT
            store_id, store_name, store_type, store_address, store_city,
            store_state, store_postal_code, store_country, store_region,
            latitude, longitude, square_feet, store_manager_name, opened_at
        FROM contoso_retail_silver_curated.dbo.store
        UNION ALL
        SELECT -1, ''Online'', ''online'', NULL, NULL, NULL, NULL, NULL, ''Online'',
               CAST(NULL AS FLOAT), CAST(NULL AS FLOAT), CAST(NULL AS INT),
               NULL, CAST(NULL AS DATE)
        UNION ALL
        SELECT -2, ''Mobile'', ''mobile'', NULL, NULL, NULL, NULL, NULL, ''Online'',
               CAST(NULL AS FLOAT), CAST(NULL AS FLOAT), CAST(NULL AS INT),
               NULL, CAST(NULL AS DATE);
    ');
END
GO

-- Builds dbo.dim_store by CTAS from the curated lakehouse shortcut.
CREATE OR ALTER PROCEDURE dbo.sp_RecreateDimStore
AS
BEGIN
    DROP TABLE IF EXISTS dbo.dim_store;
    CREATE TABLE dbo.dim_store AS
    SELECT * FROM contoso_retail_silver_curated.dbo.store
    UNION ALL
    SELECT -1 AS store_id, 'Online' AS store_name, 'online' AS store_type,
           NULL AS store_address, NULL AS store_city, NULL AS store_state,
           NULL AS store_postal_code, NULL AS store_country, 'Online' AS store_region,
           CAST(NULL AS DECIMAL(9,6)) AS latitude, CAST(NULL AS DECIMAL(9,6)) AS longitude,
           CAST(NULL AS INT) AS square_feet, NULL AS store_manager_name,
           CAST(NULL AS DATE) AS opened_at
    UNION ALL
    SELECT -2, 'Mobile', 'mobile', NULL, NULL, NULL, NULL, NULL, 'Online',
           CAST(NULL AS DECIMAL(9,6)), CAST(NULL AS DECIMAL(9,6)),
           CAST(NULL AS INT), NULL, CAST(NULL AS DATE);
END
GO

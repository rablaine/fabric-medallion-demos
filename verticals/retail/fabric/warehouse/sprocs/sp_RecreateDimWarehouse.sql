-- Builds dbo.dim_warehouse by CTAS from the curated lakehouse shortcut.
CREATE OR ALTER PROCEDURE dbo.sp_RecreateDimWarehouse
AS
BEGIN
    DROP TABLE IF EXISTS dbo.dim_warehouse;
    CREATE TABLE dbo.dim_warehouse AS
    SELECT * FROM contoso_retail_silver_mirror.dbo.warehouse;
END
GO

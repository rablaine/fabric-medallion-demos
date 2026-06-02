-- Builds dbo.dim_store by CTAS from the curated lakehouse shortcut.
CREATE OR ALTER PROCEDURE dbo.sp_RecreateDimStore
AS
BEGIN
    DROP TABLE IF EXISTS dbo.dim_store;
    CREATE TABLE dbo.dim_store AS
    SELECT * FROM contoso_retail_silver_mirror.dbo.store;
END
GO

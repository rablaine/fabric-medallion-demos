-- Builds dbo.dim_supplier by CTAS from the curated lakehouse shortcut.
CREATE OR ALTER PROCEDURE dbo.sp_RecreateDimSupplier
AS
BEGIN
    DROP TABLE IF EXISTS dbo.dim_supplier;
    CREATE TABLE dbo.dim_supplier AS
    SELECT * FROM contoso_retail_silver_curated.dbo.supplier;
END
GO

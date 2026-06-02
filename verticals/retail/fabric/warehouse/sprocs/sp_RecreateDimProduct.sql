-- Builds dbo.dim_product by CTAS from the curated lakehouse shortcut.
CREATE OR ALTER PROCEDURE dbo.sp_RecreateDimProduct
AS
BEGIN
    DROP TABLE IF EXISTS dbo.dim_product;
    CREATE TABLE dbo.dim_product AS
    SELECT * FROM contoso_retail_silver_curated.dbo.product;
END
GO

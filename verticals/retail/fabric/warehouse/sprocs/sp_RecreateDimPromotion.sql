-- Builds dbo.dim_promotion by CTAS from the curated lakehouse shortcut.
CREATE OR ALTER PROCEDURE dbo.sp_RecreateDimPromotion
AS
BEGIN
    DROP TABLE IF EXISTS dbo.dim_promotion;
    CREATE TABLE dbo.dim_promotion AS
    SELECT * FROM contoso_retail_silver_curated.dbo.promotion;
END
GO

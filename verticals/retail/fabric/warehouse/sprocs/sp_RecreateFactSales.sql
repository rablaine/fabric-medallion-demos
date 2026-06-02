-- Builds dbo.fact_sales by CTAS from the curated lakehouse shortcut.
-- One row per order line (line grain).
CREATE OR ALTER PROCEDURE dbo.sp_RecreateFactSales
AS
BEGIN
    DROP TABLE IF EXISTS dbo.fact_sales;
    CREATE TABLE dbo.fact_sales AS
    SELECT * FROM contoso_retail_silver_mirror.dbo.order_line;
END
GO

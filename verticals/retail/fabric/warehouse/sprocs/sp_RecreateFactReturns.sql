-- Builds dbo.fact_returns by CTAS from the curated lakehouse shortcut.
-- One row per return; return.order_item_id joins to fact_sales.order_item_id.
-- `return` is a T-SQL reserved word so the source table is bracketed.
CREATE OR ALTER PROCEDURE dbo.sp_RecreateFactReturns
AS
BEGIN
    DROP TABLE IF EXISTS dbo.fact_returns;
    CREATE TABLE dbo.fact_returns AS
    SELECT * FROM contoso_retail_silver_curated.dbo.[return];
END
GO

-- Builds dbo.fact_orders by CTAS from the curated lakehouse shortcut.
-- One row per order (header grain).
CREATE OR ALTER PROCEDURE dbo.sp_RecreateFactOrders
AS
BEGIN
    DROP TABLE IF EXISTS dbo.fact_orders;
    CREATE TABLE dbo.fact_orders AS
    SELECT * FROM contoso_retail_silver_mirror.dbo.[order];
END
GO

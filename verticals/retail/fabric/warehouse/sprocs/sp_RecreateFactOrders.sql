-- Builds dbo.fact_orders by CTAS from the curated lakehouse shortcut.
-- One row per order (header grain).
-- Amount columns: subtotal = pre-discount gross from source; items_total =
-- SUM(fact_sales.line_total), i.e. post-discount sum of line amounts (so
-- subtotal - items_total = total line_discount); net_amount = subtotal -
-- discount_amount; total_amount = net_amount + tax_amount + shipping_amount.
CREATE OR ALTER PROCEDURE dbo.sp_RecreateFactOrders
AS
BEGIN
    DROP TABLE IF EXISTS dbo.fact_orders;
    CREATE TABLE dbo.fact_orders AS
    SELECT * FROM contoso_retail_silver_curated.dbo.[order];
END
GO

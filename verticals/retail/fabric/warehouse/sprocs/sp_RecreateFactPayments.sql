-- Builds dbo.fact_payments by CTAS from the curated lakehouse shortcut.
-- One row per payment; payment.order_id joins to fact_orders.order_id.
CREATE OR ALTER PROCEDURE dbo.sp_RecreateFactPayments
AS
BEGIN
    DROP TABLE IF EXISTS dbo.fact_payments;
    CREATE TABLE dbo.fact_payments AS
    SELECT * FROM contoso_retail_silver_mirror.dbo.payment;
END
GO

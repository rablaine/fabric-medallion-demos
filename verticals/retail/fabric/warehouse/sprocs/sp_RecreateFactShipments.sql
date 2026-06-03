-- Builds dbo.fact_shipments by CTAS from the curated lakehouse shortcut.
-- One row per shipment; shipment.order_id -> fact_orders, shipment.warehouse_id -> dim_warehouse.
CREATE OR ALTER PROCEDURE dbo.sp_RecreateFactShipments
AS
BEGIN
    DROP TABLE IF EXISTS dbo.fact_shipments;
    CREATE TABLE dbo.fact_shipments AS
    SELECT * FROM contoso_retail_silver_curated.dbo.shipment;
END
GO

-- Builds dbo.fact_inventory by CTAS from the curated lakehouse shortcut.
-- Snapshot grain: one row per (product, location). location_type='warehouse'
-- joins fact_inventory.location_id -> dim_warehouse.warehouse_id; for
-- location_type='store' it joins to dim_store.store_id.
CREATE OR ALTER PROCEDURE dbo.sp_RecreateFactInventory
AS
BEGIN
    DROP TABLE IF EXISTS dbo.fact_inventory;
    CREATE TABLE dbo.fact_inventory AS
    SELECT * FROM contoso_retail_silver_curated.dbo.inventory;
END
GO

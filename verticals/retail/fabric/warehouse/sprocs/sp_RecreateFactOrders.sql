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
    SELECT
        order_id, order_number, customer_id, order_dt, order_date, order_year,
        order_month, order_dow, order_status, channel, currency, subtotal,
        tax_amount, shipping_amount, discount_amount, total_amount, net_amount,
        promotion_id, has_promotion, basket_size, total_units, items_total,
        customer_segment, customer_loyalty_tier, customer_tenure_days,
        customer_lifecycle_status,
        COALESCE(store_id,
                 CASE channel WHEN 'online' THEN -1 WHEN 'mobile' THEN -2 END) AS store_id,
        store_name, store_type, store_city, store_state, store_country, store_region,
        temperature_max_c, temperature_min_c, precipitation_mm, weather_description,
        ship_city, ship_state, ship_country, is_quality_suspect
    FROM contoso_retail_silver_curated.dbo.[order];
END
GO

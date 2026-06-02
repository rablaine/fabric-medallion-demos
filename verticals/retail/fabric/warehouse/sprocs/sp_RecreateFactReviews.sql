-- Builds dbo.fact_reviews by CTAS from the curated lakehouse shortcut.
-- One row per review; review.product_id -> dim_product, review.customer_id -> dim_customer.
CREATE OR ALTER PROCEDURE dbo.sp_RecreateFactReviews
AS
BEGIN
    DROP TABLE IF EXISTS dbo.fact_reviews;
    CREATE TABLE dbo.fact_reviews AS
    SELECT * FROM contoso_retail_silver_mirror.dbo.review;
END
GO

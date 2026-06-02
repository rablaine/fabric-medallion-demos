-- Builds dbo.dim_customer by CTAS from the curated lakehouse shortcut.
-- Re-creates the table each run so the schema always matches silver.
CREATE OR ALTER PROCEDURE dbo.sp_RecreateDimCustomer
AS
BEGIN
    DROP TABLE IF EXISTS dbo.dim_customer;
    CREATE TABLE dbo.dim_customer AS
    SELECT * FROM contoso_retail_silver_mirror.dbo.customer;
END
GO

-- Builds dbo.dim_employee by CTAS from the curated lakehouse shortcut.
CREATE OR ALTER PROCEDURE dbo.sp_RecreateDimEmployee
AS
BEGIN
    DROP TABLE IF EXISTS dbo.dim_employee;
    CREATE TABLE dbo.dim_employee AS
    SELECT * FROM contoso_retail_silver_mirror.dbo.employee;
END
GO

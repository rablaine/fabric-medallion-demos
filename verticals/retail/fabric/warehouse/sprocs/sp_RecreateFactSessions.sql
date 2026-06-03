-- Builds dbo.fact_sessions by CTAS from the curated lakehouse shortcut.
-- One row per web session.
CREATE OR ALTER PROCEDURE dbo.sp_RecreateFactSessions
AS
BEGIN
    DROP TABLE IF EXISTS dbo.fact_sessions;
    CREATE TABLE dbo.fact_sessions AS
    SELECT * FROM contoso_retail_silver_curated.dbo.[session];
END
GO

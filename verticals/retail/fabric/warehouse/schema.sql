-- ============================================================
-- contoso_retail_gold  --  one-time DDL
-- ============================================================
-- Schemas needed for the load sprocs. Tables themselves are
-- created (via CTAS) by the Recreate* sprocs on each run, so
-- there is no per-table CREATE TABLE here.
-- ============================================================

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'stg')
    EXEC('CREATE SCHEMA stg');
GO

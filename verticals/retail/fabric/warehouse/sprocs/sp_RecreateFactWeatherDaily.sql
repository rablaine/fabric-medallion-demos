-- Builds dbo.fact_weather_daily by CTAS from the curated lakehouse shortcut.
-- One row per (weather_date, location) at daily grain.
CREATE OR ALTER PROCEDURE dbo.sp_RecreateFactWeatherDaily
AS
BEGIN
    DROP TABLE IF EXISTS dbo.fact_weather_daily;
    CREATE TABLE dbo.fact_weather_daily AS
    SELECT * FROM contoso_retail_silver_curated.dbo.weather_daily;
END
GO

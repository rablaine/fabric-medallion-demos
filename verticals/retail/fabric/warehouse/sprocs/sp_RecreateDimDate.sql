-- Builds dbo.dim_date with fiscal year starting July 1 (FY26 = Jul 2025 - Jun 2026).
-- Calendar 2020-01-01 through 2030-12-31. Recreate on every run -- it is static and tiny.
CREATE OR ALTER PROCEDURE dbo.sp_RecreateDimDate
AS
BEGIN
    DROP TABLE IF EXISTS dbo.dim_date;

    -- Numbers table CTE: 0 .. 4017 (= days from 2020-01-01 to 2030-12-31 inclusive)
    WITH
    n0 AS (SELECT 0 AS n UNION ALL SELECT 1),
    n1 AS (SELECT 0 AS n FROM n0 a CROSS JOIN n0 b),        -- 4
    n2 AS (SELECT 0 AS n FROM n1 a CROSS JOIN n1 b),        -- 16
    n3 AS (SELECT 0 AS n FROM n2 a CROSS JOIN n2 b),        -- 256
    n4 AS (SELECT 0 AS n FROM n3 a CROSS JOIN n3 b),        -- 65,536
    nums AS (SELECT TOP (4018) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS n FROM n4),
    dates AS (
        SELECT DATEADD(DAY, n, CAST('2020-01-01' AS date)) AS d
        FROM nums
    )
    SELECT
        CAST(CONVERT(varchar(8), d, 112) AS int)                                AS date_key,
        d                                                                       AS [date],
        DATEPART(YEAR,    d)                                                    AS [year],
        DATEPART(MONTH,   d)                                                    AS [month],
        DATEPART(DAY,     d)                                                    AS [day],
        DATEPART(QUARTER, d)                                                    AS calendar_quarter,
        DATEPART(ISO_WEEK, d)                                                   AS iso_week,
        ((DATEPART(WEEKDAY, d) + @@DATEFIRST - 2) % 7) + 1                      AS day_of_week,  -- Mon=1..Sun=7
        CAST(DATENAME(WEEKDAY, d) AS varchar(20))                               AS day_name,
        CAST(DATENAME(MONTH,   d) AS varchar(20))                               AS month_name,
        CASE WHEN ((DATEPART(WEEKDAY, d) + @@DATEFIRST - 2) % 7) + 1 >= 6
             THEN CAST(1 AS bit) ELSE CAST(0 AS bit) END                        AS is_weekend,
        CASE WHEN DATEPART(MONTH, d) >= 7
             THEN DATEPART(YEAR, d) + 1
             ELSE DATEPART(YEAR, d) END                                         AS fiscal_year,
        ((DATEPART(MONTH, d) + 5) % 12) + 1                                     AS fiscal_month,  -- Jul=1..Jun=12
        (((DATEPART(MONTH, d) + 5) % 12) / 3) + 1                               AS fiscal_quarter,
        'FY' + RIGHT(CAST(
            CASE WHEN DATEPART(MONTH, d) >= 7
                 THEN DATEPART(YEAR, d) + 1
                 ELSE DATEPART(YEAR, d) END AS varchar(4)), 2)
            + '-Q' + CAST((((DATEPART(MONTH, d) + 5) % 12) / 3) + 1 AS varchar(1))
                                                                                AS fiscal_period
    INTO dbo.dim_date
    FROM dates;
END
GO

-- Builds dbo.dim_channel from a static seed. Keep in sync with channel codes in silver.
CREATE OR ALTER PROCEDURE dbo.sp_RecreateDimChannel
AS
BEGIN
    DROP TABLE IF EXISTS dbo.dim_channel;
    CREATE TABLE dbo.dim_channel
    (
        channel_code   varchar(20)  NOT NULL,
        channel_name   varchar(50)  NOT NULL,
        channel_family varchar(20)  NOT NULL
    );
    INSERT INTO dbo.dim_channel (channel_code, channel_name, channel_family)
    VALUES
        ('unknown',  'Unknown',                    'unknown'),
        ('online',   'Online',                     'web'),
        ('in_store', 'In Store',                   'physical'),
        ('mobile',   'Mobile App',                 'web'),
        ('phone',    'Phone Order',                'assisted'),
        ('pickup',   'Buy Online Pickup In Store', 'hybrid');
END
GO

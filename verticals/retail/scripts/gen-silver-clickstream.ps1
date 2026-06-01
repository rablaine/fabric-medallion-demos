. c:\dev\Contoso\verticals\retail\scripts\Build-Notebook.ps1

$cells = @()

$cells += @{ type='markdown'; source = @'
# silver_curated_clickstream

Takes raw `Clickstream` events from the bronze Eventhouse (KQL) and writes two
analyst-ready Delta tables in `silver_curated/Tables/dbo/`:

- `session_event` — one row per event, conformed and bucketed (event_date,
  event_hour, event_category, is_purchase). Kept at full grain for fine
  analysis.
- `session`       — one row per `session_id`, sessionized: event_count,
  duration_seconds, page_views, product_views, purchases, bounced, converted,
  entry_page, exit_page, device, channel, customer_id (mode), first/last_event_ts.

**Why silver:** clickstream lives in KQL for low-latency real-time queries, but
batch analytics, ML features, and joins to retail data are far easier in
Delta/Spark. Silver bridges the two: same data, lakehouse shape, plus
sessionization so a data scientist gets "one row per visit" out of the box.

Re-runnable: full overwrite.
'@ }

$cells += @{ type='code'; source = @'
# Parameters baked by deploy.ps1.
kusto_cluster_uri           = ""
kusto_database              = "contoso_retail_events"
kusto_table                 = "Clickstream"
silver_curated_workspace_id = ""
silver_curated_lakehouse_id = ""
'@ }

$cells += @{ type='code'; source = @'
from pyspark.sql import functions as F, Window as W

for n, v in [
    ('kusto_cluster_uri',           kusto_cluster_uri),
    ('silver_curated_workspace_id', silver_curated_workspace_id),
    ('silver_curated_lakehouse_id', silver_curated_lakehouse_id),
]:
    if not v:
        raise ValueError(f'{n} parameter is required')

tgt_base = f'abfss://{silver_curated_workspace_id}@onelake.dfs.fabric.microsoft.com/{silver_curated_lakehouse_id}/Tables/dbo'

def write_tgt(df, name, partition=None):
    w = (df.write.format('delta').mode('overwrite').option('overwriteSchema', 'true'))
    if partition:
        w = w.partitionBy(partition)
    w.save(f'{tgt_base}/{name}')
    print(f'{name}: wrote {df.count():,} rows -> Tables/dbo/{name}')
'@ }

$cells += @{ type='markdown'; source = @'
## 1. Load Clickstream from the bronze Eventhouse

Pull all events via the Kusto Spark connector. Token comes from `mssparkutils`
so the workspace identity authenticates against the KQL DB.
'@ }

$cells += @{ type='code'; source = @'
access_token = mssparkutils.credentials.getToken(kusto_cluster_uri)

raw = (spark.read
    .format('com.microsoft.kusto.spark.synapse.datasource')
    .option('kustoCluster', kusto_cluster_uri)
    .option('kustoDatabase', kusto_database)
    .option('kustoQuery', f'{kusto_table} | project event_id, event_ts, event_type, customer_id, product_id, session_id, device, channel, page_url')
    .option('accessToken', access_token)
    .load())

raw.printSchema()
print(f'pulled {raw.count():,} raw events')
'@ }

$cells += @{ type='markdown'; source = @'
## 2. Build `session_event` (conformed, bucketed)

Same grain as bronze, but:
- `event_date` / `event_hour` extracted for cheap partition pruning
- `event_category` rolls up granular event_type strings
- `is_purchase` boolean flag
'@ }

$cells += @{ type='code'; source = @'
session_event = (raw
    .withColumn('event_date', F.to_date('event_ts'))
    .withColumn('event_hour', F.hour('event_ts'))
    .withColumn('event_category',
        F.when(F.col('event_type') == 'purchase',          F.lit('conversion'))
         .when(F.col('event_type').isin('add_to_cart',
                                         'remove_from_cart',
                                         'checkout_start'), F.lit('cart'))
         .when(F.col('event_type').isin('product_view',
                                         'category_view',
                                         'search'),         F.lit('browse'))
         .when(F.col('event_type').isin('session_start',
                                         'session_end',
                                         'page_view'),      F.lit('navigation'))
         .otherwise(F.lit('other')))
    .withColumn('is_purchase', F.col('event_type') == F.lit('purchase')))

write_tgt(session_event, 'session_event', partition='event_date')
'@ }

$cells += @{ type='markdown'; source = @'
## 3. Build `session` (one row per session_id)

Sessionize. For each `session_id` compute:
- timing (first_event_ts, last_event_ts, duration_seconds)
- volume (event_count, page_views, product_views, cart_events, purchases)
- outcomes (converted, revenue_count, bounced)
- attribution (entry_page, exit_page, device, channel, customer_id)

`bounced = True` when the visit has <=1 page view and no cart/purchase activity.
'@ }

$cells += @{ type='code'; source = @'
w_first = W.partitionBy('session_id').orderBy(F.col('event_ts').asc())
w_last  = W.partitionBy('session_id').orderBy(F.col('event_ts').desc())

with_endpoints = (session_event
    .withColumn('_first_page',
        F.first(F.when(F.col('event_type') == 'page_view', F.col('page_url')), ignorenulls=True).over(w_first))
    .withColumn('_last_page',
        F.first(F.when(F.col('event_type') == 'page_view', F.col('page_url')), ignorenulls=True).over(w_last)))

session = (with_endpoints.groupBy('session_id')
    .agg(
        F.min('event_ts').alias('first_event_ts'),
        F.max('event_ts').alias('last_event_ts'),
        F.count('event_id').alias('event_count'),
        F.sum(F.when(F.col('event_type') == 'page_view',    1).otherwise(0)).alias('page_views'),
        F.sum(F.when(F.col('event_type') == 'product_view', 1).otherwise(0)).alias('product_views'),
        F.sum(F.when(F.col('event_category') == 'cart',     1).otherwise(0)).alias('cart_events'),
        F.sum(F.when(F.col('is_purchase'),                  1).otherwise(0)).alias('purchases'),
        F.countDistinct('product_id').alias('distinct_products_viewed'),
        F.max('customer_id').alias('customer_id'),
        F.max('device').alias('device'),
        F.max('channel').alias('channel'),
        F.max('_first_page').alias('entry_page'),
        F.max('_last_page').alias('exit_page'),
    )
    .withColumn('session_date',     F.to_date('first_event_ts'))
    .withColumn('duration_seconds', F.col('last_event_ts').cast('long') - F.col('first_event_ts').cast('long'))
    .withColumn('converted',        F.col('purchases') > 0)
    .withColumn('bounced',          (F.col('page_views') <= 1) & (F.col('cart_events') == 0) & (F.col('purchases') == 0))
    .select(
        'session_id', 'session_date',
        'first_event_ts', 'last_event_ts', 'duration_seconds',
        'event_count', 'page_views', 'product_views', 'cart_events', 'purchases',
        'distinct_products_viewed',
        'customer_id', 'device', 'channel',
        'entry_page', 'exit_page',
        'converted', 'bounced',
    ))

write_tgt(session, 'session', partition='session_date')
'@ }

$cells += @{ type='markdown'; source = @'
## 4. Verify
'@ }

$cells += @{ type='code'; source = @'
for n in ['session_event', 'session']:
    df = spark.read.format('delta').load(f'{tgt_base}/{n}')
    print(f'{n:14s}  {df.count():>9,} rows   {len(df.columns):>3} cols')

print('\nsession outcomes:')
spark.read.format('delta').load(f'{tgt_base}/session').groupBy('converted', 'bounced').count().show()
'@ }

New-Ipynb -Cells $cells -OutPath 'c:\dev\Contoso\verticals\retail\fabric\notebooks\silver\silver_curated_clickstream.ipynb'
Write-Host "ok"

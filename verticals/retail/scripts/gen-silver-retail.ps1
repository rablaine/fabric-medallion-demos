. c:\dev\Contoso\verticals\retail\scripts\Build-Notebook.ps1

$cells = @()

$cells += @{ type='markdown'; source = @'
# silver_curated_retail

Conforms and **enriches** the mirrored OLTP tables in `silver_raw` into analyst-ready Delta tables in `silver_curated/Tables/dbo/`.

**Why silver curated exists:** silver_raw is a 1:1 mirror of the source system. Analysts shouldn't have to re-join the same 5 reference tables on every query. Here we:

1. **Conform** — types, names, units; one consistent vocabulary across tables
2. **Dedupe** — latest-wins on natural key (email for customer, order_number for order)
3. **Enrich across sources** — orders pick up customer attrs, store region, and weather on the order day at the delivery store; customers pick up lifetime metrics; products pick up popularity rank
4. **Quality flags** — surface suspicious rows (`is_quality_suspect`) instead of dropping them
5. **Subject-area names** — `customer` not `customers`; `order_line` not `order_items`

Output tables:
- `customer`     - one row per customer (latest-wins), with lifetime_orders, lifetime_revenue, lifecycle_status, days_since_last_order
- `product`      - one row per product, with margin, lifetime_units_sold, lifetime_revenue, popularity_rank
- `order`        - one row per order, denormalized with customer + store + weather; basket_size, net_amount, has_promotion, is_quality_suspect
- `order_line`   - one row per order line, with product attrs, line_margin, line_margin_pct

Curated is **normalized data for data scientists and analysts**. The star schema with surrogate keys lives in gold.

Re-runnable: full overwrite. Source is the mirror, so we mirror state forward.
'@ }

$cells += @{ type='code'; source = @'
# Parameters baked by deploy.ps1.
silver_raw_workspace_id     = ""
silver_raw_lakehouse_id     = ""
silver_curated_workspace_id = ""
silver_curated_lakehouse_id = ""
'@ }

$cells += @{ type='code'; source = @'
from pyspark.sql import functions as F, Window as W

for n, v in [
    ('silver_raw_workspace_id',     silver_raw_workspace_id),
    ('silver_raw_lakehouse_id',     silver_raw_lakehouse_id),
    ('silver_curated_workspace_id', silver_curated_workspace_id),
    ('silver_curated_lakehouse_id', silver_curated_lakehouse_id),
]:
    if not v:
        raise ValueError(f'{n} parameter is required')

src_base = f'abfss://{silver_raw_workspace_id}@onelake.dfs.fabric.microsoft.com/{silver_raw_lakehouse_id}/Tables/dbo'
tgt_base = f'abfss://{silver_curated_workspace_id}@onelake.dfs.fabric.microsoft.com/{silver_curated_lakehouse_id}/Tables/dbo'

def read_src(name):
    return spark.read.format('delta').load(f'{src_base}/{name}')

def write_tgt(df, name):
    (df.write.format('delta')
        .mode('overwrite').option('overwriteSchema', 'true')
        .save(f'{tgt_base}/{name}'))
    print(f'{name}: wrote {df.count():,} rows -> Tables/dbo/{name}')
'@ }

$cells += @{ type='markdown'; source = @'
## 1. Load conformed source tables

Read from silver_raw (mirrored OLTP via shortcuts) and apply lightweight conformance: trim strings, lowercase emails, normalize date types. Nothing is aggregated yet.
'@ }

$cells += @{ type='code'; source = @'
customers_src    = read_src('customers')
products_src     = read_src('products')
orders_src       = read_src('orders')
order_items_src  = read_src('order_items')
stores_src       = read_src('stores')
segments_src     = read_src('customer_segments')
categories_src   = read_src('categories')
brands_src       = read_src('brands')
weather_src      = read_src('weather')

# light conformance
customers = (customers_src
    .withColumn('email',      F.lower(F.trim('email')))
    .withColumn('first_name', F.trim('first_name'))
    .withColumn('last_name',  F.trim('last_name')))

orders = (orders_src
    .withColumn('order_dt',    F.to_timestamp('order_date'))
    .withColumn('order_date',  F.to_date('order_date')))

for name, df in [('customers', customers), ('products', products_src), ('orders', orders),
                 ('order_items', order_items_src), ('stores', stores_src),
                 ('segments', segments_src), ('categories', categories_src),
                 ('brands', brands_src), ('weather', weather_src)]:
    print(f'  {name:12s} {df.count():>9,} rows')
'@ }

$cells += @{ type='markdown'; source = @'
## 2. Dedupe customers (latest-wins on email)

The mirror is full-state, but in a streaming silver world we'd see late-arriving updates and dupes. Demonstrate the pattern: keep the latest row per natural key. Here the natural key is `email` (also unique in source), tie-break on `created_at`.
'@ }

$cells += @{ type='code'; source = @'
w = W.partitionBy('email').orderBy(F.col('created_at').desc(), F.col('customer_id').desc())
customers_dedup = (customers
    .withColumn('_rn', F.row_number().over(w))
    .where('_rn = 1')
    .drop('_rn'))

dupes = customers.count() - customers_dedup.count()
print(f'collapsed {dupes:,} duplicate customer rows')
'@ }

$cells += @{ type='markdown'; source = @'
## 3. Pre-aggregate lifetime metrics per customer & per product

These rollups get joined onto `customer` and `product` so analysts don't have to compute them on every query. This is the heart of silver curated: **answer common questions without joins**.
'@ }

$cells += @{ type='code'; source = @'
# customer lifetime: orders + revenue + recency
cust_lifetime = (orders.groupBy('customer_id')
    .agg(
        F.count('order_id').alias('lifetime_orders'),
        F.sum('total_amount').alias('lifetime_revenue'),
        F.max('order_date').alias('last_order_date'),
        F.min('order_date').alias('first_order_date'),
    ))

# product lifetime: units + revenue + popularity rank
prod_lifetime = (order_items_src.groupBy('product_id')
    .agg(
        F.sum('quantity').alias('lifetime_units_sold'),
        F.sum('line_total').alias('lifetime_revenue'),
    ))
prod_lifetime = prod_lifetime.withColumn(
    'popularity_rank',
    F.row_number().over(W.orderBy(F.col('lifetime_revenue').desc_nulls_last()))
)
print('lifetime rollups computed')
'@ }

$cells += @{ type='markdown'; source = @'
## 4. Build `customer`

One row per customer with denormalized segment name + lifetime metrics + lifecycle bucket.
'@ }

$cells += @{ type='code'; source = @'
segments_lk = segments_src.select(
    F.col('segment_id'),
    F.col('segment_name').alias('segment_name'),
)

customer = (customers_dedup
    .join(segments_lk, 'segment_id', 'left')
    .join(cust_lifetime, 'customer_id', 'left')
    .withColumn('lifetime_orders',  F.coalesce('lifetime_orders',  F.lit(0)))
    .withColumn('lifetime_revenue', F.coalesce('lifetime_revenue', F.lit(0.0)))
    .withColumn('full_name',         F.concat_ws(' ', 'first_name', 'last_name'))
    .withColumn('signup_date',       F.to_date('created_at'))
    .withColumn('tenure_days',       F.datediff(F.current_date(), F.to_date('created_at')))
    .withColumn('days_since_last_order',
        F.when(F.col('last_order_date').isNotNull(),
               F.datediff(F.current_date(), F.col('last_order_date'))))
    .withColumn('lifecycle_status',
        F.when(F.col('lifetime_orders') == 0, F.lit('new'))
         .when(F.col('days_since_last_order') <= 90,  F.lit('active'))
         .when(F.col('days_since_last_order') <= 365, F.lit('dormant'))
         .otherwise(F.lit('churned')))
    .select(
        'customer_id', 'email', 'first_name', 'last_name', 'full_name',
        'phone', 'date_of_birth',
        'segment_id', 'segment_name',
        'city', 'state', 'postal_code', 'country',
        'loyalty_tier', 'loyalty_points', 'marketing_opt_in',
        'signup_date', 'tenure_days', 'last_login_at', 'is_active',
        'lifetime_orders', 'lifetime_revenue',
        'first_order_date', 'last_order_date', 'days_since_last_order',
        'lifecycle_status',
    ))

write_tgt(customer, 'customer')
'@ }

$cells += @{ type='markdown'; source = @'
## 5. Build `product`

Denormalize category + brand names. Add margin metrics and lifetime sales rollups. `popularity_rank = 1` is the best seller by revenue.
'@ }

$cells += @{ type='code'; source = @'
categories_lk = categories_src.select(
    F.col('category_id'),
    F.col('category_name'),
    F.col('category_path'),
)
brands_lk = brands_src.select(
    F.col('brand_id'),
    F.col('brand_name'),
    F.col('is_premium').alias('is_premium_brand'),
)

product = (products_src
    .join(categories_lk, 'category_id', 'left')
    .join(brands_lk,     'brand_id',    'left')
    .join(prod_lifetime, 'product_id',  'left')
    .withColumn('margin',         F.col('list_price') - F.col('cost'))
    .withColumn('margin_pct',
        F.when(F.col('list_price') > 0,
               (F.col('list_price') - F.col('cost')) / F.col('list_price')))
    .withColumn('lifetime_units_sold', F.coalesce('lifetime_units_sold', F.lit(0)))
    .withColumn('lifetime_revenue',    F.coalesce('lifetime_revenue',    F.lit(0.0)))
    .withColumn('is_discontinued',     F.col('discontinued_at').isNotNull())
    .select(
        'product_id', 'sku', 'product_name',
        'category_id', 'category_name', 'category_path',
        'brand_id', 'brand_name', 'is_premium_brand',
        'list_price', 'cost', 'margin', 'margin_pct',
        'color', 'model_year', 'warranty_months',
        'is_active', 'is_discontinued', 'launched_at', 'discontinued_at',
        'lifetime_units_sold', 'lifetime_revenue', 'popularity_rank',
    ))

write_tgt(product, 'product')
'@ }

$cells += @{ type='markdown'; source = @'
## 6. Build `order` (enriched with customer + store + weather)

This is the silver headline. One order row carries:
- order facts (subtotal, tax, discount, total, channel, status, promotion flag)
- **customer attrs** (segment, loyalty_tier, tenure_band) - no join required
- **store attrs** (region, country) for in-store/pickup orders
- **weather on the order date at the delivery/pickup store** - the cross-source enrichment that makes silver valuable
- a basket size + quality flag
'@ }

$cells += @{ type='code'; source = @'
# 6a. Basket size per order from order_items
basket = (order_items_src.groupBy('order_id')
    .agg(
        F.count('order_item_id').alias('basket_size'),
        F.sum('quantity').alias('total_units'),
        F.sum('line_total').alias('items_total'),
    ))

# 6b. Customer attrs to denormalize onto orders
cust_attrs = customer.select(
    'customer_id',
    F.col('segment_name').alias('customer_segment'),
    F.col('loyalty_tier').alias('customer_loyalty_tier'),
    F.col('tenure_days').alias('customer_tenure_days'),
    F.col('lifecycle_status').alias('customer_lifecycle_status'),
)

# 6c. Store attrs
store_attrs = stores_src.select(
    'store_id',
    F.col('store_name'),
    F.col('store_type'),
    F.col('city').alias('store_city'),
    F.col('state').alias('store_state'),
    F.col('country').alias('store_country'),
    F.col('region').alias('store_region'),
)

# 6d. Weather on order day at store
weather_lk = weather_src.select(
    F.col('store_id'),
    F.col('date').alias('order_date'),
    F.col('temperature_max_c'),
    F.col('temperature_min_c'),
    F.col('precipitation_mm'),
    F.col('weather_description'),
)
'@ }

$cells += @{ type='code'; source = @'
order = (orders
    .join(basket,      'order_id',    'left')
    .join(cust_attrs,  'customer_id', 'left')
    .join(store_attrs, 'store_id',    'left')
    .join(weather_lk,  ['store_id', 'order_date'], 'left')
    .withColumn('order_year',  F.year('order_date'))
    .withColumn('order_month', F.month('order_date'))
    .withColumn('order_dow',   F.date_format('order_date', 'E'))
    .withColumn('net_amount',  F.col('subtotal') - F.col('discount_amount'))
    .withColumn('has_promotion', F.col('promotion_id').isNotNull())
    # quality flag: header total should equal items + tax + shipping - discount, within a cent
    .withColumn('_expected_total',
        F.coalesce('items_total', F.lit(0.0)) + F.col('tax_amount')
        + F.col('shipping_amount') - F.col('discount_amount'))
    .withColumn('is_quality_suspect',
        F.abs(F.col('total_amount') - F.col('_expected_total')) > F.lit(0.01))
    .drop('_expected_total')
    .select(
        # identity
        'order_id', 'order_number', 'customer_id',
        # timing
        'order_dt', 'order_date', 'order_year', 'order_month', 'order_dow',
        # status / channel
        'order_status', 'channel',
        # money
        'currency', 'subtotal', 'tax_amount', 'shipping_amount', 'discount_amount',
        'total_amount', 'net_amount',
        # promo
        'promotion_id', 'has_promotion',
        # basket
        'basket_size', 'total_units', 'items_total',
        # customer enrichment
        'customer_segment', 'customer_loyalty_tier',
        'customer_tenure_days', 'customer_lifecycle_status',
        # store enrichment (NULL for pure online)
        'store_id', 'store_name', 'store_type',
        'store_city', 'store_state', 'store_country', 'store_region',
        # weather enrichment at store on order_date
        'temperature_max_c', 'temperature_min_c', 'precipitation_mm', 'weather_description',
        # shipping
        'ship_city', 'ship_state', 'ship_country',
        # quality
        'is_quality_suspect',
    ))

write_tgt(order, 'order')
'@ }

$cells += @{ type='markdown'; source = @'
## 7. Build `order_line` (product-enriched line items)

Denormalize product name, category, brand, list_price, cost onto each line. Compute line_margin so analysts get profitability without joining `product`.
'@ }

$cells += @{ type='code'; source = @'
prod_for_lines = product.select(
    'product_id',
    F.col('product_name'),
    F.col('sku'),
    F.col('category_name'),
    F.col('brand_name'),
    F.col('list_price').alias('product_list_price'),
    F.col('cost').alias('product_cost'),
)

order_line = (order_items_src
    .join(prod_for_lines, 'product_id', 'left')
    .withColumn('line_gross',  F.col('quantity') * F.col('unit_price'))
    .withColumn('line_margin', F.col('line_total') - (F.col('quantity') * F.col('product_cost')))
    .withColumn('line_margin_pct',
        F.when(F.col('line_total') > 0,
               F.col('line_margin') / F.col('line_total')))
    .select(
        'order_item_id', 'order_id', 'product_id',
        'sku', 'product_name', 'category_name', 'brand_name',
        'quantity', 'unit_price', 'line_discount', 'line_total',
        'line_gross', 'line_margin', 'line_margin_pct',
        'product_list_price', 'product_cost',
        'fulfillment_warehouse_id',
    ))

write_tgt(order_line, 'order_line')
'@ }

$cells += @{ type='markdown'; source = @'
## 8. Verify
'@ }

$cells += @{ type='code'; source = @'
for n in ['customer', 'product', 'order', 'order_line']:
    df = spark.read.format('delta').load(f'{tgt_base}/{n}')
    print(f'{n:12s}  {df.count():>9,} rows   {len(df.columns):>3} cols')
'@ }

$cells += @{ type='code'; source = @'
# Show enrichment is real
o = spark.read.format("delta").load(f"{tgt_base}/order")
o.where(F.col("store_id").isNotNull()).select(
    "order_id", "channel", "store_region", "customer_segment",
    "weather_description", "precipitation_mm", "total_amount", "is_quality_suspect"
).show(10, truncate=False)
'@ }

New-Ipynb -Cells $cells -OutPath 'c:\dev\Contoso\verticals\retail\fabric\notebooks\silver\silver_curated_retail.ipynb'
Write-Host "ok"

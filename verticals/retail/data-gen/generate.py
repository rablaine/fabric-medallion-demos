"""
Contoso Tech - Retail Synthetic Data Generator
===============================================
Generates realistic consumer-electronics retail data and either:
  - Writes INSERT statements to a .sql file (default, no DB required)
  - Loads directly into Azure SQL via AAD token (--load flag)

Usage:
    python generate.py --scale small --output ../data/seed-small.sql
    python generate.py --scale medium --output ../data/seed-medium.sql
    python generate.py --scale small --load --server contoso3-retail-sql-xxx.database.windows.net --database contoso_retail

Scale row counts:
    small  : 1 000 customers | 500 products | 10 000 orders
    medium : 50 000 customers | 5 000 products | 500 000 orders
    large  : 1 000 000 customers | 20 000 products | 10 000 000 orders
"""

import argparse
import datetime
import math
import random
import struct
import subprocess
import sys
import uuid
from io import StringIO
from pathlib import Path

try:
    from faker import Faker
except ImportError:
    sys.exit("faker not installed. Run: pip install -r requirements.txt")

try:
    from tqdm import tqdm
except ImportError:
    # Fallback no-op if tqdm not available
    def tqdm(iterable, **kwargs):
        return iterable

fake = Faker("en_US")
Faker.seed(42)
random.seed(42)

# ---------------------------------------------------------------------------
# Scale definitions
# ---------------------------------------------------------------------------
SCALES = {
    "small":  dict(customers=1_000,    products=500,    orders=10_000),
    "medium": dict(customers=50_000,   products=5_000,  orders=500_000),
    "large":  dict(customers=1_000_000, products=20_000, orders=10_000_000),
}

# ---------------------------------------------------------------------------
# Contoso Tech product catalog (consumer electronics)
# ---------------------------------------------------------------------------

CATEGORIES = [
    # (id, parent_id, name, path)
    (1,  None, "Electronics",        "Electronics"),
    (2,  1,    "Smartphones",        "Electronics > Smartphones"),
    (3,  1,    "Laptops",            "Electronics > Laptops"),
    (4,  1,    "Tablets",            "Electronics > Tablets"),
    (5,  1,    "Headphones",         "Electronics > Headphones"),
    (6,  1,    "Smart Watches",      "Electronics > Smart Watches"),
    (7,  1,    "Cameras",            "Electronics > Cameras"),
    (8,  1,    "Smart Home",         "Electronics > Smart Home"),
    (9,  1,    "Gaming",             "Electronics > Gaming"),
    (10, 9,    "Consoles",           "Electronics > Gaming > Consoles"),
    (11, 9,    "Controllers",        "Electronics > Gaming > Controllers"),
    (12, 9,    "Gaming Headsets",    "Electronics > Gaming > Gaming Headsets"),
    (13, 1,    "Accessories",        "Electronics > Accessories"),
    (14, 13,   "Cables & Adapters",  "Electronics > Accessories > Cables & Adapters"),
    (15, 13,   "Cases & Protection", "Electronics > Accessories > Cases & Protection"),
    (16, 13,   "Chargers",           "Electronics > Accessories > Chargers"),
    (17, 1,    "Monitors",           "Electronics > Monitors"),
    (18, 1,    "Printers",           "Electronics > Printers"),
    (19, 1,    "Networking",         "Electronics > Networking"),
    (20, 1,    "Storage",            "Electronics > Storage"),
]

BRANDS = [
    # (id, name, country, is_premium)
    (1,  "Nexova",      "USA",          1),
    (2,  "Lumex",       "South Korea",  1),
    (3,  "Orion Tech",  "Japan",        1),
    (4,  "Vantara",     "USA",          0),
    (5,  "Prism",       "China",        0),
    (6,  "Stellarwave", "Germany",      1),
    (7,  "Kodra",       "Taiwan",       0),
    (8,  "Zephyr",      "USA",          0),
    (9,  "ArcLight",    "Japan",        1),
    (10, "Dynamo",      "China",        0),
]

SUPPLIERS = [
    # (id, name, email, country, lead_days)
    (1,  "Pacific Rim Electronics",  "orders@pacificrim.example",   "China",      21),
    (2,  "MidWest Tech Supply",      "purchasing@mwtech.example",   "USA",         7),
    (3,  "Euro Components Ltd",      "supply@eurocomp.example",     "Germany",    18),
    (4,  "Seoul Direct",             "biz@seouldirect.example",     "South Korea", 14),
    (5,  "Tokyo Parts Co",           "import@tokyoparts.example",   "Japan",      20),
    (6,  "Shenzhen Global",          "sales@szhglobal.example",     "China",      25),
    (7,  "Apex Logistics",           "ops@apexlogistics.example",   "USA",         5),
]

WAREHOUSES = [
    # (id, name, city, state, country, capacity)
    (1, "Central Distribution Center", "Kansas City", "MO", "USA", 100_000),
    (2, "West Coast Fulfillment",       "Reno",        "NV", "USA",  80_000),
    (3, "East Coast Hub",               "Columbus",    "OH", "USA",  90_000),
    (4, "Southern Logistics",           "Dallas",      "TX", "USA",  70_000),
]

STORES = [
    # (id, name, type, addr, city, state, postal, country, opened, sqft, manager)
    (1,  "Contoso Tech - Manhattan",     "flagship",   "450 5th Ave",         "New York",      "NY", "10018", "USA", "2018-03-15", 12000, "Sarah Chen"),
    (2,  "Contoso Tech - Chicago Loop",  "retail",     "101 W Madison St",    "Chicago",       "IL", "60602", "USA", "2019-06-01",  8500, "Marcus Webb"),
    (3,  "Contoso Tech - LA Hollywood",  "retail",     "6801 Hollywood Blvd", "Los Angeles",   "CA", "90028", "USA", "2019-11-20",  9200, "Elena Torres"),
    (4,  "Contoso Tech - Houston",       "retail",     "1200 McKinney Ave",   "Houston",       "TX", "77010", "USA", "2020-02-14",  7800, "James Okafor"),
    (5,  "Contoso Tech - Seattle",       "retail",     "400 Pine St",         "Seattle",       "WA", "98101", "USA", "2020-08-03",  8100, "Linda Park"),
    (6,  "Contoso Tech - Miami",         "retail",     "701 Brickell Ave",    "Miami",         "FL", "33131", "USA", "2021-01-12",  7200, "Carlos Diaz"),
    (7,  "Contoso Tech - Phoenix",       "retail",     "1 E Washington St",   "Phoenix",       "AZ", "85004", "USA", "2021-05-18",  6900, "Amy Russell"),
    (8,  "Contoso Tech - Boston",        "retail",     "800 Boylston St",     "Boston",        "MA", "02199", "USA", "2022-03-01",  7500, "Derek Hughes"),
    (9,  "Contoso Tech - Denver",        "retail",     "500 16th St",         "Denver",        "CO", "80202", "USA", "2022-09-10",  6500, "Priya Sharma"),
    (10, "Contoso Tech - Atlanta",       "retail",     "3393 Peachtree Rd",   "Atlanta",       "GA", "30326", "USA", "2023-02-28",  7000, "Nathan King"),
]

# Products: (category_id, name_prefix, brand_ids, price_range, cost_fraction, colors, warranty_months)
PRODUCT_TEMPLATES = [
    (2,  "Pro Smartphone",      [1, 2, 4],    (499,  1299), 0.45, ["Black", "White", "Blue", "Silver"], 12),
    (2,  "Smartphone SE",       [4, 5, 7],    (199,   499), 0.40, ["Black", "White", "Red"],           12),
    (3,  "UltraBook",           [1, 3, 6],    (799,  2499), 0.42, ["Space Gray", "Silver", "Black"],   12),
    (3,  "Gaming Laptop",       [1, 3, 8],    (999,  3499), 0.40, ["Black", "Red"],                    12),
    (3,  "Business Laptop",     [3, 6, 7],    (699,  1899), 0.43, ["Silver", "Black"],                 24),
    (4,  "Pro Tablet",          [1, 2, 9],    (349,   999), 0.44, ["Black", "Silver", "Gold"],         12),
    (4,  "Budget Tablet",       [5, 7, 10],   (99,    349), 0.38, ["Black", "White"],                  12),
    (5,  "Wireless Headphones", [2, 6, 9],    (79,    399), 0.35, ["Black", "White", "Blue"],          12),
    (5,  "Earbuds Pro",         [1, 2, 9],    (99,    299), 0.36, ["White", "Black", "Sage"],          12),
    (6,  "Smart Watch",         [1, 2, 4],    (199,   799), 0.40, ["Black", "Silver", "Gold", "Blue"], 12),
    (7,  "Mirrorless Camera",   [3, 9],       (699,  3999), 0.38, ["Black", "Silver"],                 12),
    (7,  "Action Camera",       [4, 8],       (149,   499), 0.37, ["Black"],                           12),
    (8,  "Smart Speaker",       [1, 4, 8],    (49,    299), 0.32, ["Charcoal", "White", "Sage"],       12),
    (8,  "Smart Display",       [1, 4],       (99,    349), 0.33, ["Charcoal", "White"],               12),
    (10, "Gaming Console",      [3, 1],       (299,   599), 0.55, ["Black", "White"],                  12),
    (11, "Game Controller",     [3, 1, 8],    (39,    179), 0.40, ["Black", "White", "Red", "Blue"],   12),
    (12, "Gaming Headset",      [2, 6, 8],    (49,    249), 0.38, ["Black", "Red"],                    12),
    (14, "USB-C Cable 6ft",     [7, 10],      (9,      29), 0.25, ["Black", "White"],                  6),
    (14, "HDMI Cable 10ft",     [7, 10],      (12,     49), 0.25, ["Black"],                           6),
    (15, "Phone Case",          [7, 8, 10],   (14,     59), 0.28, ["Black", "Clear", "Blue", "Red"],   6),
    (16, "65W USB-C Charger",   [1, 7, 10],   (19,     79), 0.30, ["Black", "White"],                  12),
    (16, "MagCharge Pad",       [1, 4],       (29,     99), 0.32, ["Black", "White"],                  12),
    (17, "4K Monitor 27\"",     [2, 3, 6],    (299,  1299), 0.42, ["Black", "Silver"],                 36),
    (17, "Gaming Monitor 165Hz",[2, 8],       (249,   999), 0.41, ["Black"],                           24),
    (18, "All-in-One Printer",  [3, 6],       (99,    499), 0.36, ["White", "Black"],                  12),
    (19, "WiFi 6 Router",       [4, 8],       (79,    349), 0.38, ["Black", "White"],                  24),
    (19, "Mesh WiFi System",    [1, 4, 8],    (149,   599), 0.38, ["White"],                           24),
    (20, "Portable SSD 1TB",    [2, 3, 7],    (79,    199), 0.40, ["Black", "Silver", "Blue"],         36),
    (20, "USB Flash Drive",     [7, 10],      (9,      39), 0.28, ["Black", "Silver", "Red"],           6),
    (20, "NAS Drive 4TB",       [3, 6],       (149,   499), 0.42, ["Black"],                           36),
]

# ---------------------------------------------------------------------------
# Helper to escape SQL strings
# ---------------------------------------------------------------------------
def sq(s: str) -> str:
    if s is None:
        return "NULL"
    return "'" + str(s).replace("'", "''") + "'"

def sqn(v) -> str:
    if v is None:
        return "NULL"
    return str(v)

def sqd(d) -> str:
    if d is None:
        return "NULL"
    return f"'{d}'"

def sqbit(b: bool) -> str:
    return "1" if b else "0"

# ---------------------------------------------------------------------------
# Bulk INSERT helper — batches rows into multi-row VALUES blocks
# ---------------------------------------------------------------------------
def write_inserts(out, table: str, columns: list, rows: list, batch: int = 500):
    if not rows:
        return
    col_list = ", ".join(columns)
    for i in range(0, len(rows), batch):
        chunk = rows[i:i + batch]
        vals = ",\n       ".join(f"({r})" for r in chunk)
        out.write(f"INSERT INTO {table} ({col_list})\nVALUES {vals};\n")
    out.write("GO\n\n")

# ---------------------------------------------------------------------------
# Generator
# ---------------------------------------------------------------------------

def generate(scale: str) -> str:
    counts = SCALES[scale]
    n_customers = counts["customers"]
    n_products  = counts["products"]
    n_orders    = counts["orders"]

    out = StringIO()
    out.write("-- ============================================================\n")
    out.write(f"-- Contoso Tech - Retail Seed Data ({scale} scale)\n")
    out.write(f"-- Generated {datetime.date.today().isoformat()}\n")
    out.write("-- ============================================================\n\n")
    out.write("SET NOCOUNT ON;\n\n")

    # ------------------------------------------------------------------
    # 1. Categories
    # ------------------------------------------------------------------
    out.write("-- Categories\n")
    rows = []
    for cat_id, parent_id, name, path in CATEGORIES:
        rows.append(
            f"{cat_id}, {sqn(parent_id)}, {sq(name)}, {sq(path)}, {CATEGORIES.index((cat_id, parent_id, name, path))}"
        )
    write_inserts(out, "retail.categories",
                  ["category_id", "parent_category_id", "category_name", "category_path", "sort_order"], rows)

    # ------------------------------------------------------------------
    # 2. Brands
    # ------------------------------------------------------------------
    out.write("-- Brands\n")
    rows = []
    for b_id, name, country, premium in BRANDS:
        rows.append(f"{b_id}, {sq(name)}, {sq(country)}, {sqbit(premium)}")
    write_inserts(out, "retail.brands",
                  ["brand_id", "brand_name", "country_of_origin", "is_premium"], rows)

    # ------------------------------------------------------------------
    # 3. Suppliers
    # ------------------------------------------------------------------
    out.write("-- Suppliers\n")
    rows = []
    for s_id, name, email, country, lead in SUPPLIERS:
        rows.append(f"{s_id}, {sq(name)}, {sq(email)}, {sq(country)}, {lead}")
    write_inserts(out, "retail.suppliers",
                  ["supplier_id", "supplier_name", "contact_email", "country", "lead_time_days"], rows)

    # ------------------------------------------------------------------
    # 4. Warehouses
    # ------------------------------------------------------------------
    out.write("-- Warehouses\n")
    rows = []
    for w_id, name, city, state, country, cap in WAREHOUSES:
        rows.append(f"{w_id}, {sq(name)}, {sq(city)}, {sq(state)}, {sq(country)}, {cap}")
    write_inserts(out, "retail.warehouses",
                  ["warehouse_id", "warehouse_name", "city", "state", "country", "capacity_units"], rows)

    # ------------------------------------------------------------------
    # 5. Stores
    # ------------------------------------------------------------------
    out.write("-- Stores\n")
    rows = []
    for s in STORES:
        s_id, name, stype, addr, city, state, postal, country, opened, sqft, mgr = s
        rows.append(
            f"{s_id}, {sq(name)}, {sq(stype)}, {sq(addr)}, {sq(city)}, {sq(state)}, "
            f"{sq(postal)}, {sq(country)}, {sq(opened)}, {sqft}, {sq(mgr)}"
        )
    write_inserts(out, "retail.stores",
                  ["store_id", "store_name", "store_type", "address_line1", "city", "state",
                   "postal_code", "country", "opened_at", "square_feet", "manager_name"], rows)

    # ------------------------------------------------------------------
    # 6. Products
    # ------------------------------------------------------------------
    out.write(f"-- Products ({n_products})\n")
    products = []   # list of (product_id, category_id, brand_id, supplier_id, list_price)
    product_id = 1
    templates_cycle = PRODUCT_TEMPLATES * math.ceil(n_products / len(PRODUCT_TEMPLATES))
    rows = []
    for tmpl in templates_cycle[:n_products]:
        cat_id, name_prefix, brand_ids, price_range, cost_frac, colors, warranty = tmpl
        brand_id    = random.choice(brand_ids)
        supplier_id = random.randint(1, len(SUPPLIERS))
        color       = random.choice(colors)
        list_price  = round(random.uniform(*price_range), 2)
        cost        = round(list_price * cost_frac, 2)
        model_year  = random.randint(2020, 2025)
        sku         = f"CT-{product_id:06d}"
        name        = f"{next(b[1] for b in BRANDS if b[0] == brand_id)} {name_prefix} {color} ({model_year})"
        weight      = round(random.uniform(0.05, 4.5), 3)
        launched    = fake.date_between(start_date=datetime.date(2020, 1, 1),
                                        end_date=datetime.date(2025, 1, 1))
        upc         = str(random.randint(10**11, 10**12 - 1))

        rows.append(
            f"{sq(sku)}, {sq(name)}, NULL, {cat_id}, {brand_id}, {supplier_id}, "
            f"{list_price}, {cost}, {weight}, NULL, {sq(color)}, {model_year}, "
            f"{sq(upc)}, {warranty}, 1, {sq(launched)}, NULL"
        )
        products.append((product_id, cat_id, brand_id, supplier_id, list_price))
        product_id += 1

    write_inserts(out, "retail.products",
                  ["sku", "product_name", "description", "category_id", "brand_id", "supplier_id",
                   "list_price", "cost", "weight_kg", "dimensions_cm", "color", "model_year",
                   "upc", "warranty_months", "is_active", "launched_at", "discontinued_at"], rows)

    # ------------------------------------------------------------------
    # 7. Customers
    # ------------------------------------------------------------------
    out.write(f"-- Customers ({n_customers})\n")
    segment_weights = [1, 2, 3, 4, 1, 2, 3, 4]  # weighted toward consumer
    loyalty_tiers   = ["Bronze", "Silver", "Gold", "Platinum"]
    loyalty_weights = [0.60, 0.25, 0.12, 0.03]
    rows = []
    for _ in tqdm(range(n_customers), desc="customers", leave=False):
        first     = fake.first_name()
        last      = fake.last_name()
        email_uid = uuid.uuid4().hex[:8]
        email     = f"{first.lower()}.{last.lower()}.{email_uid}@{fake.free_email_domain()}"
        phone     = fake.numerify("###-###-####")
        dob       = fake.date_of_birth(minimum_age=18, maximum_age=80)
        seg_id    = random.choices([1, 2, 3, 4], weights=[60, 25, 10, 5])[0]
        loyalty   = random.choices(loyalty_tiers, weights=loyalty_weights)[0]
        points    = random.randint(0, 50000)
        opt_in    = sqbit(random.random() < 0.55)
        created   = fake.date_time_between(start_date="-5y", end_date="now")
        last_login = fake.date_time_between(start_date=created, end_date="now") if random.random() < 0.8 else None

        rows.append(
            f"{sq(email)}, {sq(first)}, {sq(last)}, {sq(phone)}, {sq(dob)}, "
            f"{seg_id}, {sq(fake.street_address())}, NULL, {sq(fake.city())}, "
            f"{sq(fake.state_abbr())}, {sq(fake.zipcode())}, 'USA', "
            f"{sq(loyalty)}, {points}, {opt_in}, {sq(created)}, {sq(last_login)}, 1"
        )

    write_inserts(out, "retail.customers",
                  ["email", "first_name", "last_name", "phone", "date_of_birth", "segment_id",
                   "address_line1", "address_line2", "city", "state", "postal_code", "country",
                   "loyalty_tier", "loyalty_points", "marketing_opt_in", "created_at",
                   "last_login_at", "is_active"], rows)

    # ------------------------------------------------------------------
    # 8. Inventory
    # ------------------------------------------------------------------
    out.write("-- Inventory\n")
    rows = []
    for pid, _, _, _, _ in products:
        for wh_id, *_ in WAREHOUSES:
            qty = random.randint(0, 500)
            rows.append(
                f"{pid}, 'warehouse', {wh_id}, {qty}, 0, "
                f"{random.randint(5, 50)}, {random.randint(25, 200)}, "
                f"{sq(fake.date_time_between(start_date='-1y', end_date='now'))}"
            )
    write_inserts(out, "retail.inventory",
                  ["product_id", "location_type", "location_id", "quantity_on_hand",
                   "quantity_reserved", "reorder_point", "reorder_quantity", "last_restocked_at"], rows)

    # ------------------------------------------------------------------
    # 9. Promotions
    # ------------------------------------------------------------------
    out.write("-- Promotions\n")
    promo_names = [
        ("SUMMER25",    "Summer Sale 25% Off",          "percent",      25, 50),
        ("SAVE50",      "$50 Off Orders Over $500",      "fixed",        50, 500),
        ("BOGO_CABLE",  "Buy One Get One Cables",        "bogo",          0, 0),
        ("FREESHIP",    "Free Shipping Sitewide",        "free_shipping", 0, 0),
        ("FALL15",      "Fall 15% Off",                 "percent",      15, 0),
        ("HOLIDAY20",   "Holiday 20% Off",              "percent",      20, 100),
        ("NEWUSER10",   "New Customer 10% Off",         "percent",      10, 0),
        ("BFRIDAY30",   "Black Friday 30% Off",         "percent",      30, 0),
        ("CYBERMON",    "Cyber Monday $75 Off",         "fixed",        75, 300),
        ("BACK2SCHOOL", "Back to School 12% Off",       "percent",      12, 0),
        ("LOYALTY25",   "Loyalty Member $25 Off",       "fixed",        25, 150),
        ("FLASH40",     "Flash Sale 40% Off",           "percent",      40, 200),
    ]
    rows = []
    start_base = datetime.datetime(2022, 1, 1)
    for code, name, dtype, dval, min_amt in promo_names:
        start = start_base + datetime.timedelta(days=random.randint(0, 900))
        end   = start + datetime.timedelta(days=random.randint(7, 60))
        limit = random.choice([None, 500, 1000, 5000])
        rows.append(
            f"{sq(code)}, {sq(name)}, {sq(dtype)}, {dval}, {min_amt}, "
            f"{sq(start)}, {sq(end)}, {sqn(limit)}, 0"
        )
    write_inserts(out, "retail.promotions",
                  ["promo_code", "promo_name", "discount_type", "discount_value", "min_order_amount",
                   "starts_at", "ends_at", "usage_limit", "times_used"], rows)

    # collect promo_ids for FK use
    promo_ids = list(range(1, len(promo_names) + 1))

    # ------------------------------------------------------------------
    # 10. Orders + order_items + payments + shipments
    # ------------------------------------------------------------------
    out.write(f"-- Orders ({n_orders}) + order_items + payments + shipments\n")

    channels = ["online", "store", "mobile"]
    channel_weights = [0.60, 0.20, 0.20]
    carriers = ["UPS", "FedEx", "USPS", "DHL"]
    payment_methods = ["credit_card", "debit_card", "paypal", "apple_pay", "google_pay",
                       "store_credit", "gift_card"]
    payment_weights = [0.45, 0.20, 0.15, 0.08, 0.05, 0.04, 0.03]
    card_brands     = ["Visa", "Mastercard", "Amex", "Discover", None, None, None]

    order_rows    = []
    item_rows     = []
    payment_rows  = []
    shipment_rows = []
    return_rows   = []
    review_rows   = []

    delivered_items = []  # for returns + reviews

    # map order number -> sequential ints we control (IDENTITY managed by DB)
    # We track estimated order_id and item_id for FK references
    order_id = 0
    item_id  = 0
    seq_tracker = 0  # for order_number uniqueness

    print(f"  Generating {n_orders:,} orders...")
    batch_size = 5000
    flush_at   = batch_size

    def flush_batch(f_out):
        nonlocal order_rows, item_rows, payment_rows, shipment_rows

        write_inserts(f_out, "retail.orders",
                      ["order_number","customer_id","order_date","order_status","channel",
                       "store_id","subtotal","tax_amount","shipping_amount","discount_amount",
                       "total_amount","currency","promotion_id",
                       "ship_address_line1","ship_city","ship_state","ship_postal_code","ship_country"],
                      order_rows)
        write_inserts(f_out, "retail.order_items",
                      ["order_id","product_id","quantity","unit_price","line_discount",
                       "line_total","fulfillment_warehouse_id"],
                      item_rows)
        write_inserts(f_out, "retail.payments",
                      ["order_id","payment_method","card_brand","card_last_four",
                       "amount","status","transaction_ref","processed_at"],
                      payment_rows)
        write_inserts(f_out, "retail.shipments",
                      ["order_id","warehouse_id","carrier","tracking_number",
                       "shipped_at","estimated_delivery","delivered_at","status"],
                      shipment_rows)
        order_rows.clear(); item_rows.clear()
        payment_rows.clear(); shipment_rows.clear()

    for _ in tqdm(range(n_orders), desc="orders", leave=False):
        order_id += 1
        seq_tracker += 1
        cust_id   = random.randint(1, n_customers)
        channel   = random.choices(channels, weights=channel_weights)[0]
        store_id  = random.randint(1, len(STORES)) if channel == "store" else None
        promo_id  = random.choice([None, None, None] + promo_ids)
        order_date = fake.date_time_between(start_date="-3y", end_date="now")
        order_num  = f"ORD-{seq_tracker:010d}"

        n_items   = random.choices([1, 2, 3, 4, 5], weights=[40, 30, 15, 10, 5])[0]
        subtotal  = 0.0
        discount  = 0.0

        for _ in range(n_items):
            item_id += 1
            pid, _, _, _, list_price = random.choice(products)
            qty        = random.randint(1, 3)
            unit_price = round(list_price * random.uniform(0.85, 1.0), 2)
            line_gross = round(unit_price * qty, 2)
            line_disc  = round(line_gross * (0.1 if promo_id else 0), 2)
            line_total = round(line_gross - line_disc, 2)
            wh_id      = random.randint(1, len(WAREHOUSES))
            subtotal  += line_gross   # pre-discount; schema's discount_amount tracks the reduction
            discount  += line_disc
            item_rows.append(
                f"{order_id}, {pid}, {qty}, {unit_price}, {line_disc}, {line_total}, {wh_id}"
            )

        tax      = round((subtotal - discount) * 0.08, 2)
        shipping = 0.0 if (subtotal - discount) > 99 else round(random.uniform(5.99, 14.99), 2)
        total    = round(subtotal - discount + tax + shipping, 2)

        statuses      = ["delivered", "delivered", "delivered", "shipped", "paid", "cancelled"]
        status_weights= [55, 15, 5, 10, 10, 5]
        status = random.choices(statuses, weights=status_weights)[0]

        order_rows.append(
            f"{sq(order_num)}, {cust_id}, {sq(order_date)}, {sq(status)}, {sq(channel)}, "
            f"{sqn(store_id)}, {round(subtotal,2)}, {tax}, {shipping}, {round(discount,2)}, "
            f"{total}, 'USD', {sqn(promo_id)}, "
            f"{sq(fake.street_address())}, {sq(fake.city())}, {sq(fake.state_abbr())}, "
            f"{sq(fake.zipcode())}, 'USA'"
        )

        # Payment
        pm       = random.choices(payment_methods, weights=payment_weights)[0]
        cb       = random.choice(card_brands) if "card" in pm else None
        cl4      = fake.numerify("####") if cb else None
        pay_status = "captured" if status != "cancelled" else "voided"
        txn_ref  = uuid.uuid4().hex.upper()[:20]
        payment_rows.append(
            f"{order_id}, {sq(pm)}, {sq(cb)}, {sq(cl4)}, {total}, "
            f"{sq(pay_status)}, {sq(txn_ref)}, {sq(order_date)}"
        )

        # Shipment (only for non-store, non-cancelled)
        if channel != "store" and status not in ("cancelled", "paid"):
            carrier  = random.choice(carriers)
            tracking = f"{carrier[:3].upper()}{uuid.uuid4().hex[:12].upper()}"
            wh_id    = random.randint(1, len(WAREHOUSES))
            shipped  = fake.date_time_between(start_date=order_date, end_date="now") \
                        if status in ("shipped", "delivered") else None
            est_del  = (shipped.date() + datetime.timedelta(days=random.randint(2, 7))) \
                        if shipped else None
            delivered = fake.date_time_between(start_date=shipped, end_date="now") \
                        if status == "delivered" and shipped else None
            ship_status = {"delivered": "delivered", "shipped": "in_transit",
                           "paid": "label_created"}.get(status, "label_created")
            shipment_rows.append(
                f"{order_id}, {wh_id}, {sq(carrier)}, {sq(tracking)}, "
                f"{sq(shipped)}, {sq(est_del)}, {sq(delivered)}, {sq(ship_status)}"
            )
            if status == "delivered" and delivered:
                delivered_items.append((order_id, item_id, cust_id))

        if len(order_rows) >= flush_at:
            flush_batch(out)

    flush_batch(out)  # final flush

    # ------------------------------------------------------------------
    # 11. Returns (~5% of delivered items)
    # ------------------------------------------------------------------
    out.write("-- Returns\n")
    return_reasons = [
        "Defective product", "Not as described", "Wrong item shipped",
        "Changed my mind", "Better price found", "Arrived damaged",
        "Missing parts", "Incompatible with device",
    ]
    rows = []
    for o_id, oi_id, c_id in random.sample(delivered_items, min(len(delivered_items), max(1, len(delivered_items) // 20))):
        reason   = random.choice(return_reasons)
        qty      = 1
        refund   = round(random.uniform(20, 500), 2)
        r_status = random.choice(["refunded", "refunded", "received", "requested"])
        req_at   = fake.date_time_between(start_date="-1y", end_date="now")
        comp_at  = fake.date_time_between(start_date=req_at, end_date="now") \
                    if r_status in ("refunded", "received") else None
        rows.append(
            f"{o_id}, {oi_id}, {c_id}, {sq(reason)}, {qty}, {refund}, "
            f"{sq(r_status)}, {sq(req_at)}, {sq(comp_at)}"
        )
    write_inserts(out, "retail.returns",
                  ["order_id", "order_item_id", "customer_id", "return_reason", "quantity",
                   "refund_amount", "return_status", "requested_at", "completed_at"], rows)

    # ------------------------------------------------------------------
    # 12. Reviews (~15% of delivered orders)
    # ------------------------------------------------------------------
    out.write("-- Reviews\n")
    review_titles = {
        5: ["Love it!", "Absolutely amazing", "Best purchase ever", "Highly recommend"],
        4: ["Really good", "Great product", "Very happy", "Works as expected"],
        3: ["It's okay", "Decent for the price", "Mixed feelings", "Average"],
        2: ["Disappointed", "Not worth it", "Some issues", "Expected more"],
        1: ["Terrible", "Waste of money", "Do not buy", "Complete junk"],
    }
    rows = []
    review_pool = random.sample(delivered_items, min(len(delivered_items), max(1, len(delivered_items) * 15 // 100)))
    for o_id, oi_id, c_id in review_pool:
        pid    = random.randint(1, len(products))
        rating = random.choices([5, 4, 3, 2, 1], weights=[40, 30, 15, 10, 5])[0]
        title  = random.choice(review_titles[rating])
        created = fake.date_time_between(start_date="-2y", end_date="now")
        rows.append(
            f"{pid}, {c_id}, {o_id}, {rating}, {sq(title)}, NULL, "
            f"{random.randint(0, 50)}, {sq(created)}, 1"
        )
    write_inserts(out, "retail.reviews",
                  ["product_id", "customer_id", "order_id", "rating", "review_title",
                   "review_text", "helpful_count", "created_at", "is_verified_purchase"], rows)

    out.write("-- Done\nSET NOCOUNT OFF;\nGO\n")
    return out.getvalue()


# ---------------------------------------------------------------------------
# Azure SQL loader (AAD token via az CLI)
# ---------------------------------------------------------------------------
def load_to_sql(sql: str, server: str, database: str):
    try:
        import pyodbc
    except ImportError:
        sys.exit("pyodbc not installed. Run: pip install -r requirements.txt")

    print("  Getting AAD access token via az CLI...")
    result = subprocess.run(
        ["az", "account", "get-access-token",
         "--resource", "https://database.windows.net/",
         "--query", "accessToken", "-o", "tsv"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        sys.exit(f"Failed to get AAD token:\n{result.stderr}")
    token = result.stdout.strip()

    # Convert token to bytes for pyodbc SQL_COPT_SS_ACCESS_TOKEN
    token_bytes  = token.encode("utf-16-le")
    token_struct = struct.pack(f"<I{len(token_bytes)}s", len(token_bytes), token_bytes)

    conn_str = (
        f"DRIVER={{ODBC Driver 18 for SQL Server}};"
        f"SERVER={server};DATABASE={database};Encrypt=yes;TrustServerCertificate=no;"
    )
    print(f"  Connecting to {server}/{database}...")
    conn = pyodbc.connect(conn_str, attrs_before={1256: token_struct})
    conn.autocommit = False
    cursor = conn.cursor()

    statements = [s.strip() for s in sql.split("\nGO\n") if s.strip() and not s.strip().startswith("--")]
    print(f"  Executing {len(statements)} statement batches...")
    for i, stmt in enumerate(tqdm(statements, desc="loading"), 1):
        if stmt.upper() in ("SET NOCOUNT ON;", "SET NOCOUNT OFF;"):
            continue
        cursor.execute(stmt)

    conn.commit()
    cursor.close()
    conn.close()
    print("  Done.")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="Contoso Tech retail data generator")
    parser.add_argument("--scale", choices=["small", "medium", "large"], default="small",
                        help="Data volume (default: small)")
    parser.add_argument("--output", type=str,
                        help="Write SQL to this file (default: ../data/seed-{scale}.sql)")
    parser.add_argument("--load", action="store_true",
                        help="Load directly into Azure SQL (requires --server and --database)")
    parser.add_argument("--server", type=str,
                        help="Azure SQL server FQDN (e.g. contoso3-retail-sql-xxx.database.windows.net)")
    parser.add_argument("--database", type=str, default="contoso_retail",
                        help="Database name (default: contoso_retail)")
    args = parser.parse_args()

    if args.load and not args.server:
        parser.error("--load requires --server")

    out_path = args.output or str(
        Path(__file__).parent.parent / "data" / f"seed-{args.scale}.sql"
    )

    print(f"Generating {args.scale} dataset...")
    sql = generate(args.scale)

    Path(out_path).parent.mkdir(parents=True, exist_ok=True)
    Path(out_path).write_text(sql, encoding="utf-8")
    size_mb = Path(out_path).stat().st_size / 1_048_576
    print(f"Written to {out_path} ({size_mb:.1f} MB)")

    if args.load:
        print(f"Loading into {args.server}/{args.database}...")
        load_to_sql(sql, args.server, args.database)
        print("Load complete.")


if __name__ == "__main__":
    main()

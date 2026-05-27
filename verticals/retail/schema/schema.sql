-- =============================================================================
-- Contoso Tech - Retail Schema (Azure SQL Database)
-- =============================================================================
-- Idempotent DDL for the canonical OLTP store.
-- Safe to re-run; uses IF NOT EXISTS guards.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Schema
-- -----------------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'retail')
    EXEC('CREATE SCHEMA retail');
GO

-- -----------------------------------------------------------------------------
-- Reference: customer_segments
-- -----------------------------------------------------------------------------
IF OBJECT_ID('retail.customer_segments', 'U') IS NULL
CREATE TABLE retail.customer_segments (
    segment_id      INT             NOT NULL PRIMARY KEY,
    segment_name    NVARCHAR(50)    NOT NULL UNIQUE,
    description     NVARCHAR(255)   NULL
);
GO

-- -----------------------------------------------------------------------------
-- customers (PII)
-- -----------------------------------------------------------------------------
IF OBJECT_ID('retail.customers', 'U') IS NULL
CREATE TABLE retail.customers (
    customer_id         BIGINT          IDENTITY(1,1) NOT NULL PRIMARY KEY,
    email               NVARCHAR(255)   NOT NULL UNIQUE,
    first_name          NVARCHAR(100)   NOT NULL,
    last_name           NVARCHAR(100)   NOT NULL,
    phone               NVARCHAR(20)    NULL,
    date_of_birth       DATE            NULL,
    segment_id          INT             NOT NULL,
    address_line1       NVARCHAR(255)   NULL,
    address_line2       NVARCHAR(255)   NULL,
    city                NVARCHAR(100)   NULL,
    state               NVARCHAR(50)    NULL,
    postal_code         NVARCHAR(20)    NULL,
    country             NVARCHAR(50)    NULL,
    loyalty_tier        NVARCHAR(20)    NOT NULL DEFAULT 'Bronze',
    loyalty_points      INT             NOT NULL DEFAULT 0,
    marketing_opt_in    BIT             NOT NULL DEFAULT 0,
    created_at          DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME(),
    last_login_at       DATETIME2       NULL,
    is_active           BIT             NOT NULL DEFAULT 1,
    CONSTRAINT FK_customers_segment FOREIGN KEY (segment_id)
        REFERENCES retail.customer_segments(segment_id)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_customers_email')
    CREATE INDEX IX_customers_email ON retail.customers(email);
GO

-- -----------------------------------------------------------------------------
-- categories (hierarchical)
-- -----------------------------------------------------------------------------
IF OBJECT_ID('retail.categories', 'U') IS NULL
CREATE TABLE retail.categories (
    category_id         INT             NOT NULL PRIMARY KEY,
    parent_category_id  INT             NULL,
    category_name       NVARCHAR(100)   NOT NULL,
    category_path       NVARCHAR(500)   NOT NULL,
    sort_order          INT             NOT NULL DEFAULT 0,
    CONSTRAINT FK_categories_parent FOREIGN KEY (parent_category_id)
        REFERENCES retail.categories(category_id)
);
GO

-- -----------------------------------------------------------------------------
-- brands
-- -----------------------------------------------------------------------------
IF OBJECT_ID('retail.brands', 'U') IS NULL
CREATE TABLE retail.brands (
    brand_id            INT             NOT NULL PRIMARY KEY,
    brand_name          NVARCHAR(100)   NOT NULL UNIQUE,
    country_of_origin   NVARCHAR(50)    NULL,
    is_premium          BIT             NOT NULL DEFAULT 0
);
GO

-- -----------------------------------------------------------------------------
-- suppliers
-- -----------------------------------------------------------------------------
IF OBJECT_ID('retail.suppliers', 'U') IS NULL
CREATE TABLE retail.suppliers (
    supplier_id         INT             NOT NULL PRIMARY KEY,
    supplier_name       NVARCHAR(255)   NOT NULL,
    contact_email       NVARCHAR(255)   NULL,
    country             NVARCHAR(50)    NULL,
    lead_time_days      INT             NOT NULL DEFAULT 14
);
GO

-- -----------------------------------------------------------------------------
-- products
-- -----------------------------------------------------------------------------
IF OBJECT_ID('retail.products', 'U') IS NULL
CREATE TABLE retail.products (
    product_id          BIGINT          IDENTITY(1,1) NOT NULL PRIMARY KEY,
    sku                 NVARCHAR(50)    NOT NULL UNIQUE,
    product_name        NVARCHAR(255)   NOT NULL,
    description         NVARCHAR(MAX)   NULL,
    category_id         INT             NOT NULL,
    brand_id            INT             NOT NULL,
    supplier_id         INT             NOT NULL,
    list_price          DECIMAL(10,2)   NOT NULL,
    cost                DECIMAL(10,2)   NOT NULL,
    weight_kg           DECIMAL(8,3)    NULL,
    dimensions_cm       NVARCHAR(50)    NULL,
    color               NVARCHAR(50)    NULL,
    model_year          INT             NULL,
    upc                 NVARCHAR(20)    NULL,
    warranty_months     INT             NOT NULL DEFAULT 12,
    is_active           BIT             NOT NULL DEFAULT 1,
    launched_at         DATE            NULL,
    discontinued_at     DATE            NULL,
    CONSTRAINT FK_products_category FOREIGN KEY (category_id) REFERENCES retail.categories(category_id),
    CONSTRAINT FK_products_brand    FOREIGN KEY (brand_id)    REFERENCES retail.brands(brand_id),
    CONSTRAINT FK_products_supplier FOREIGN KEY (supplier_id) REFERENCES retail.suppliers(supplier_id)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_products_category')
    CREATE INDEX IX_products_category ON retail.products(category_id);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_products_brand')
    CREATE INDEX IX_products_brand ON retail.products(brand_id);
GO

-- -----------------------------------------------------------------------------
-- warehouses
-- -----------------------------------------------------------------------------
IF OBJECT_ID('retail.warehouses', 'U') IS NULL
CREATE TABLE retail.warehouses (
    warehouse_id        INT             NOT NULL PRIMARY KEY,
    warehouse_name      NVARCHAR(100)   NOT NULL,
    city                NVARCHAR(100)   NOT NULL,
    state               NVARCHAR(50)    NULL,
    country             NVARCHAR(50)    NOT NULL,
    capacity_units      INT             NOT NULL
);
GO

-- -----------------------------------------------------------------------------
-- stores (physical retail)
-- -----------------------------------------------------------------------------
IF OBJECT_ID('retail.stores', 'U') IS NULL
CREATE TABLE retail.stores (
    store_id            INT             NOT NULL PRIMARY KEY,
    store_name          NVARCHAR(100)   NOT NULL,
    store_type          NVARCHAR(50)    NOT NULL,
    address_line1       NVARCHAR(255)   NOT NULL,
    city                NVARCHAR(100)   NOT NULL,
    state               NVARCHAR(50)    NULL,
    postal_code         NVARCHAR(20)    NULL,
    country             NVARCHAR(50)    NOT NULL,
    opened_at           DATE            NOT NULL,
    square_feet         INT             NULL,
    manager_name        NVARCHAR(100)   NULL
);
GO

-- -----------------------------------------------------------------------------
-- inventory (per warehouse OR store)
-- -----------------------------------------------------------------------------
IF OBJECT_ID('retail.inventory', 'U') IS NULL
CREATE TABLE retail.inventory (
    inventory_id        BIGINT          IDENTITY(1,1) NOT NULL PRIMARY KEY,
    product_id          BIGINT          NOT NULL,
    location_type       NVARCHAR(20)    NOT NULL,
    location_id         INT             NOT NULL,
    quantity_on_hand    INT             NOT NULL DEFAULT 0,
    quantity_reserved   INT             NOT NULL DEFAULT 0,
    reorder_point       INT             NOT NULL DEFAULT 10,
    reorder_quantity    INT             NOT NULL DEFAULT 50,
    last_restocked_at   DATETIME2       NULL,
    CONSTRAINT FK_inventory_product FOREIGN KEY (product_id) REFERENCES retail.products(product_id),
    CONSTRAINT CK_inventory_location_type CHECK (location_type IN ('warehouse', 'store'))
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_inventory_product_location')
    CREATE INDEX IX_inventory_product_location ON retail.inventory(product_id, location_type, location_id);
GO

-- -----------------------------------------------------------------------------
-- promotions
-- -----------------------------------------------------------------------------
IF OBJECT_ID('retail.promotions', 'U') IS NULL
CREATE TABLE retail.promotions (
    promotion_id        INT             IDENTITY(1,1) NOT NULL PRIMARY KEY,
    promo_code          NVARCHAR(50)    NOT NULL UNIQUE,
    promo_name          NVARCHAR(255)   NOT NULL,
    discount_type       NVARCHAR(20)    NOT NULL,
    discount_value      DECIMAL(10,2)   NOT NULL,
    min_order_amount    DECIMAL(10,2)   NOT NULL DEFAULT 0,
    starts_at           DATETIME2       NOT NULL,
    ends_at             DATETIME2       NOT NULL,
    usage_limit         INT             NULL,
    times_used          INT             NOT NULL DEFAULT 0,
    CONSTRAINT CK_promotions_discount_type CHECK (discount_type IN ('percent', 'fixed', 'bogo', 'free_shipping'))
);
GO

-- -----------------------------------------------------------------------------
-- orders
-- -----------------------------------------------------------------------------
IF OBJECT_ID('retail.orders', 'U') IS NULL
CREATE TABLE retail.orders (
    order_id            BIGINT          IDENTITY(1,1) NOT NULL PRIMARY KEY,
    order_number        NVARCHAR(20)    NOT NULL UNIQUE,
    customer_id         BIGINT          NOT NULL,
    order_date          DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME(),
    order_status        NVARCHAR(30)    NOT NULL DEFAULT 'pending',
    channel             NVARCHAR(20)    NOT NULL,
    store_id            INT             NULL,
    subtotal            DECIMAL(12,2)   NOT NULL,
    tax_amount          DECIMAL(10,2)   NOT NULL DEFAULT 0,
    shipping_amount     DECIMAL(10,2)   NOT NULL DEFAULT 0,
    discount_amount     DECIMAL(10,2)   NOT NULL DEFAULT 0,
    total_amount        DECIMAL(12,2)   NOT NULL,
    currency            CHAR(3)         NOT NULL DEFAULT 'USD',
    promotion_id        INT             NULL,
    ship_address_line1  NVARCHAR(255)   NULL,
    ship_city           NVARCHAR(100)   NULL,
    ship_state          NVARCHAR(50)    NULL,
    ship_postal_code    NVARCHAR(20)    NULL,
    ship_country        NVARCHAR(50)    NULL,
    CONSTRAINT FK_orders_customer  FOREIGN KEY (customer_id)  REFERENCES retail.customers(customer_id),
    CONSTRAINT FK_orders_store     FOREIGN KEY (store_id)     REFERENCES retail.stores(store_id),
    CONSTRAINT FK_orders_promotion FOREIGN KEY (promotion_id) REFERENCES retail.promotions(promotion_id),
    CONSTRAINT CK_orders_channel CHECK (channel IN ('online', 'store', 'mobile')),
    CONSTRAINT CK_orders_status  CHECK (order_status IN ('pending','paid','shipped','delivered','cancelled','refunded'))
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_orders_customer')
    CREATE INDEX IX_orders_customer ON retail.orders(customer_id);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_orders_order_date')
    CREATE INDEX IX_orders_order_date ON retail.orders(order_date);
GO

-- -----------------------------------------------------------------------------
-- order_items
-- -----------------------------------------------------------------------------
IF OBJECT_ID('retail.order_items', 'U') IS NULL
CREATE TABLE retail.order_items (
    order_item_id           BIGINT      IDENTITY(1,1) NOT NULL PRIMARY KEY,
    order_id                BIGINT      NOT NULL,
    product_id              BIGINT      NOT NULL,
    quantity                INT         NOT NULL,
    unit_price              DECIMAL(10,2) NOT NULL,
    line_discount           DECIMAL(10,2) NOT NULL DEFAULT 0,
    line_total              DECIMAL(12,2) NOT NULL,
    fulfillment_warehouse_id INT        NULL,
    CONSTRAINT FK_order_items_order     FOREIGN KEY (order_id)                 REFERENCES retail.orders(order_id),
    CONSTRAINT FK_order_items_product   FOREIGN KEY (product_id)               REFERENCES retail.products(product_id),
    CONSTRAINT FK_order_items_warehouse FOREIGN KEY (fulfillment_warehouse_id) REFERENCES retail.warehouses(warehouse_id)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_order_items_order')
    CREATE INDEX IX_order_items_order ON retail.order_items(order_id);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_order_items_product')
    CREATE INDEX IX_order_items_product ON retail.order_items(product_id);
GO

-- -----------------------------------------------------------------------------
-- payments
-- -----------------------------------------------------------------------------
IF OBJECT_ID('retail.payments', 'U') IS NULL
CREATE TABLE retail.payments (
    payment_id          BIGINT          IDENTITY(1,1) NOT NULL PRIMARY KEY,
    order_id            BIGINT          NOT NULL,
    payment_method      NVARCHAR(30)    NOT NULL,
    card_brand          NVARCHAR(20)    NULL,
    card_last_four      CHAR(4)         NULL,
    amount              DECIMAL(12,2)   NOT NULL,
    status              NVARCHAR(20)    NOT NULL,
    transaction_ref     NVARCHAR(100)   NULL,
    processed_at        DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT FK_payments_order FOREIGN KEY (order_id) REFERENCES retail.orders(order_id),
    CONSTRAINT CK_payments_method CHECK (payment_method IN ('credit_card','debit_card','paypal','apple_pay','google_pay','store_credit','gift_card')),
    CONSTRAINT CK_payments_status CHECK (status IN ('authorized','captured','refunded','failed','voided'))
);
GO

-- -----------------------------------------------------------------------------
-- shipments
-- -----------------------------------------------------------------------------
IF OBJECT_ID('retail.shipments', 'U') IS NULL
CREATE TABLE retail.shipments (
    shipment_id         BIGINT          IDENTITY(1,1) NOT NULL PRIMARY KEY,
    order_id            BIGINT          NOT NULL,
    warehouse_id        INT             NOT NULL,
    carrier             NVARCHAR(50)    NOT NULL,
    tracking_number     NVARCHAR(100)   NULL,
    shipped_at          DATETIME2       NULL,
    estimated_delivery  DATE            NULL,
    delivered_at        DATETIME2       NULL,
    status              NVARCHAR(30)    NOT NULL DEFAULT 'label_created',
    CONSTRAINT FK_shipments_order     FOREIGN KEY (order_id)     REFERENCES retail.orders(order_id),
    CONSTRAINT FK_shipments_warehouse FOREIGN KEY (warehouse_id) REFERENCES retail.warehouses(warehouse_id),
    CONSTRAINT CK_shipments_status CHECK (status IN ('label_created','in_transit','out_for_delivery','delivered','exception','returned'))
);
GO

-- -----------------------------------------------------------------------------
-- returns
-- -----------------------------------------------------------------------------
IF OBJECT_ID('retail.returns', 'U') IS NULL
CREATE TABLE retail.returns (
    return_id           BIGINT          IDENTITY(1,1) NOT NULL PRIMARY KEY,
    order_id            BIGINT          NOT NULL,
    order_item_id       BIGINT          NOT NULL,
    customer_id         BIGINT          NOT NULL,
    return_reason       NVARCHAR(100)   NOT NULL,
    quantity            INT             NOT NULL,
    refund_amount       DECIMAL(10,2)   NOT NULL,
    return_status       NVARCHAR(30)    NOT NULL DEFAULT 'requested',
    requested_at        DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME(),
    completed_at        DATETIME2       NULL,
    CONSTRAINT FK_returns_order      FOREIGN KEY (order_id)      REFERENCES retail.orders(order_id),
    CONSTRAINT FK_returns_order_item FOREIGN KEY (order_item_id) REFERENCES retail.order_items(order_item_id),
    CONSTRAINT FK_returns_customer   FOREIGN KEY (customer_id)   REFERENCES retail.customers(customer_id),
    CONSTRAINT CK_returns_status CHECK (return_status IN ('requested','received','refunded','rejected'))
);
GO

-- -----------------------------------------------------------------------------
-- reviews
-- -----------------------------------------------------------------------------
IF OBJECT_ID('retail.reviews', 'U') IS NULL
CREATE TABLE retail.reviews (
    review_id               BIGINT      IDENTITY(1,1) NOT NULL PRIMARY KEY,
    product_id              BIGINT      NOT NULL,
    customer_id             BIGINT      NOT NULL,
    order_id                BIGINT      NULL,
    rating                  TINYINT     NOT NULL,
    review_title            NVARCHAR(255) NULL,
    review_text             NVARCHAR(MAX) NULL,
    helpful_count           INT         NOT NULL DEFAULT 0,
    created_at              DATETIME2   NOT NULL DEFAULT SYSUTCDATETIME(),
    is_verified_purchase    BIT         NOT NULL DEFAULT 0,
    CONSTRAINT FK_reviews_product  FOREIGN KEY (product_id)  REFERENCES retail.products(product_id),
    CONSTRAINT FK_reviews_customer FOREIGN KEY (customer_id) REFERENCES retail.customers(customer_id),
    CONSTRAINT FK_reviews_order    FOREIGN KEY (order_id)    REFERENCES retail.orders(order_id),
    CONSTRAINT CK_reviews_rating CHECK (rating BETWEEN 1 AND 5)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_reviews_product')
    CREATE INDEX IX_reviews_product ON retail.reviews(product_id);
GO

-- =============================================================================
-- Seed reference data
-- =============================================================================
IF NOT EXISTS (SELECT 1 FROM retail.customer_segments)
INSERT INTO retail.customer_segments (segment_id, segment_name, description) VALUES
    (1, 'Consumer',       'Individual retail shoppers'),
    (2, 'Small Business', 'SMB customers (up to 50 employees)'),
    (3, 'Enterprise',     'Large business accounts'),
    (4, 'Education',      'Schools, universities, students');
GO

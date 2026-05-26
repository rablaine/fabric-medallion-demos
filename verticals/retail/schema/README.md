# Retail Schema

> TODO: Design ER diagram and SQL DDL.

## Planned Entities

| Entity | Store | Purpose |
|--------|-------|---------|
| `customers` | Azure SQL | Customer profiles, addresses |
| `products` | Azure SQL | Product catalog (SKU, name, price, category) |
| `categories` | Azure SQL | Product hierarchy |
| `suppliers` | Azure SQL | Product sources |
| `orders` | Azure SQL | Order headers |
| `order_items` | Azure SQL | Order line items |
| `inventory` | Azure SQL | Per-warehouse stock levels |
| `warehouses` | Azure SQL | Warehouse locations |
| `returns` | Azure SQL | Product returns |
| `cart_sessions` | Cosmos DB | In-progress shopping carts |
| `clickstream_events` | Event Hub → ADLS | Page views, clicks, search queries |

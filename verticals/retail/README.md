# Retail Vertical

A fictional online retailer "Contoso Commerce" with full Azure data estate.

## What Gets Deployed

- **Azure SQL Database** - Transactional store (customers, products, orders, inventory)
- **Azure Cosmos DB** - Shopping cart and session state
- **Azure Data Lake Storage Gen2** - Raw and curated data zones
- **Microsoft Fabric** - Analytics workspace with Lakehouse and Power BI
- **Azure Event Hub** - Clickstream event ingestion
- **Microsoft Purview** - Data catalog and governance

## Data Model

See [schema/README.md](schema/README.md) for entity-relationship details.

Core entities:
- `customers` - shoppers
- `products` - catalog (with categories, suppliers)
- `orders` + `order_items` - transactions
- `inventory` + `warehouses` - stock levels
- `clickstream_events` - browsing behavior (streamed)

## Synthetic Data

See [data-gen/README.md](data-gen/README.md). Scale options:
- **small**: ~1k customers, ~500 products, ~10k orders
- **medium**: ~50k customers, ~5k products, ~500k orders
- **large**: ~1M customers, ~20k products, ~10M orders

## Analytics

See [analytics/README.md](analytics/README.md) for Fabric notebooks and Power BI dashboards.

## Deployment

This is a stub. Deployment templates will live in [infra/](infra/). The web app will generate a customized package from these templates.

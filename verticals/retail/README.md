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

Generated on demand by a Fabric notebook (Phase B) — no seed file ships in the deployment zip. The repo's `data-gen/` folder is a dev tool used to author and test the Faker templates that the notebook will reuse.

## Analytics

See [analytics/README.md](analytics/README.md) for Fabric notebooks and Power BI dashboards.

## Deployment

This is a stub. Deployment templates will live in [infra/](infra/). The web app will generate a customized package from these templates.

# Retail Vertical

Fictional consumer-electronics retailer "Contoso Commerce" with a full Azure data estate: OLTP, batch landing, real-time clickstream, and a Fabric medallion (bronze / silver / gold) on top.

## What Gets Deployed

- **Azure SQL Database** (serverless Gen5) - transactional store (customers, products, orders, inventory, payments, shipments, returns, reviews) with change tracking
- **Azure Data Lake Storage Gen2** - `raw/` and `curated/` containers
- **Azure Functions** (Flex Consumption / FC1) - timer-triggered clickstream emitter that writes straight to a Fabric Eventstream CustomEndpoint (no Azure Event Hubs namespace required)
- **VNet + SQL Private Endpoint + Fabric VNet Data Gateway** - private SQL path; `publicNetworkAccess` is disabled by the end of deploy
- **Microsoft Fabric F8 capacity** - bronze / silver / gold workspaces with lakehouses, SQL Mirror, Eventhouse + KQL DB, warehouse, semantic models, Power BI reports, and natural-language data agents

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

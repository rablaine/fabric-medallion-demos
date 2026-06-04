# Retail Infrastructure (Bicep)

## Files

- `main.bicep` - top-level orchestrator
- `modules/sql.bicep` - Azure SQL Server + Database (AAD-only auth, firewall rules; `publicNetworkAccess` flipped to Disabled by `deploy.ps1` once the private path is verified)
- `modules/storage.bicep` - ADLS Gen2 storage with `raw` + `curated` containers
- `modules/network.bicep` - VNet (`10.50.0.0/16`) with `snet-gateway` (delegated to `Microsoft.PowerPlatform/vnetaccesslinks`) and `snet-pe` (Private Endpoint subnet)
- `modules/sql-pe.bicep` - Private Endpoint to the SQL server + `privatelink.database.windows.net` private DNS zone linked to the VNet
- `modules/function.bicep` - Azure Functions (Flex Consumption / FC1) Python emitter app

## Parameters

| Name | Description |
|---|---|
| `resourcePrefix` | Lowercase alphanumeric naming prefix (max 12 chars) |
| `location` | Azure region |
| `sqlAdminObjectId` | AAD Object ID granted SQL admin (set by deploy.ps1 to caller) |
| `sqlAdminLoginName` | UPN of the SQL admin |
| `clientIpAddress` | Public IP added to SQL firewall (auto-detected by deploy.ps1) |

## Fixed SKUs

| Resource | SKU | Notes |
|---|---|---|
| SQL Database | GP_S_Gen5_8 (Serverless) at deploy time; scaled down to GP_S_Gen5_4 (4 vCore, min 0.5) after seed completes | Auto-pauses after 60 min idle; 128 GB max |
| Storage | Standard_LRS | ADLS Gen2 with raw + curated containers |
| Function Plan | FC1 (Flex Consumption, Linux) | Python 3.11, identity-based deployment |

## Out of Scope

Clickstream is emitted by the Function App directly to a Fabric Eventstream CustomEndpoint (Event Hubs wire protocol, no Azure Event Hubs namespace). The Fabric Eventhouse / KQL DB / Eventstream are all created by `deploy.ps1` via the Fabric REST API, not Bicep.

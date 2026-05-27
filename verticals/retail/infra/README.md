# Retail Infrastructure (Bicep)

## Files

- `main.bicep` - top-level orchestrator
- `modules/sql.bicep` - Azure SQL Server + Database (AAD-only auth, firewall rules)
- `modules/storage.bicep` - ADLS Gen2 storage with `raw` + `curated` containers

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

## Phase 1 Scope

Currently deploys only SQL + Storage. Coming next:

- Cosmos DB account + cart_sessions / wishlists containers
- Event Hub namespace + clickstream hub
- Key Vault for connection secrets
- Purview account (governance)
- Fabric workspace (created via REST, not Bicep)

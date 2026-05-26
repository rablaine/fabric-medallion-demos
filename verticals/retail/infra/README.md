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
| `scale` | `small` / `medium` / `large` - drives SKUs |
| `sqlAdminObjectId` | AAD Object ID granted SQL admin (set by deploy.ps1 to caller) |
| `sqlAdminLoginName` | UPN of the SQL admin |
| `clientIpAddress` | Public IP added to SQL firewall (auto-detected by deploy.ps1) |

## SKU Scaling

| Scale | SQL DB | Storage |
|---|---|---|
| small | Basic (5 DTU) | Standard_LRS |
| medium | S0 (10 DTU) | Standard_LRS |
| large | S2 (50 DTU) | Standard_ZRS |

## Phase 1 Scope

Currently deploys only SQL + Storage. Coming next:

- Cosmos DB account + cart_sessions / wishlists containers
- Event Hub namespace + clickstream hub
- Key Vault for connection secrets
- Purview account (governance)
- Fabric workspace (created via REST, not Bicep)

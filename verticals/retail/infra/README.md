# Retail Infrastructure (Bicep)

> TODO: Author Bicep templates for all Azure resources.

## Planned Files

- `main.bicep` - top-level orchestrator
- `modules/sql.bicep` - Azure SQL Database + firewall
- `modules/cosmos.bicep` - Cosmos DB account + container
- `modules/storage.bicep` - ADLS Gen2 with raw/curated containers
- `modules/eventhub.bicep` - Event Hub namespace + hub
- `modules/fabric.bicep` - Fabric capacity (if available via Bicep)
- `modules/purview.bicep` - Purview account
- `modules/identity.bicep` - User-assigned managed identity + role assignments
- `modules/keyvault.bicep` - Key Vault for secrets

## Parameters

- `location` - Azure region
- `resourcePrefix` - naming prefix for all resources
- `scale` - small / medium / large (drives SKUs)
- `tags` - common tags

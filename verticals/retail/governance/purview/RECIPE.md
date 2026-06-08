# Purview Integration Recipe

> **Source of truth** for everything that worked. Capture verbs, URLs, body shapes, order, gotchas.
> When this is complete and proven, port into `verticals/retail/deploy.ps1`.

## Environment

- **Subscription**: `97aba503-25b6-46a2-8ed2-a8afc3bfbd23` (ME-MngEnvMCAP094505-alexbla-1)
- **Tenant**: `96d12531-723e-46c1-842b-0480739c7419`
- **User**: `admin@techier.net`
- **Test RG**: `rg-contoso-retail-forpurview` (centralus)
- **Purview account**: TBD (auto-discover via `az purview account list`)
- **Retail SP**: TBD (read from deploy output)

## Critical Constraints

- **No failed scans allowed.** Failed scan attempts retry forever and bill ~$0.50/asset/month per failed attempt. If we can't establish a working connection for a data source, do NOT register the scan — fail the script loudly instead.
- **Soft delete tombstone**: Purview accounts soft-delete; we don't create the account so this is the org's problem, but Data Sources / Scans / Glossary / Domains we create DO need clean removal.
- **Auto-discover everything.** No hardcoded names — read from deploy outputs or `az` queries.

## Phase Order (test order)

| # | Phase | Script | Status |
|---|-------|--------|--------|
| 1 | Auto-discover Purview account, retail resources | `00-discover.ps1` | not started |
| 2 | Check + enable Fabric→Purview tenant link | `01-fabric-link.ps1` | not started |
| 3 | Networking: managed VNet runtime + managed PEs for SQL/ADLS | `02-networking.ps1` | not started |
| 4 | Register credentials (Key Vault refs for SQL; MSI for ADLS/Fabric) | `03-credentials.ps1` | not started |
| 5 | Register data sources (Azure SQL, ADLS Gen2, Fabric) | `04-sources.ps1` | not started |
| 6 | Define + trigger scans, poll to completion | `05-scans.ps1` | not started |
| 7 | Create governance domains (Contoso-Retail, Contoso-Retail-HR) | `06-domains.ps1` | not started |
| 8 | Create glossary terms | `07-glossary.ps1` | not started |
| 9 | Create data products + attach scanned assets | `08-data-products.ps1` | not started |
| 10 | (Optional) Push manual lineage where auto-discovery missed | `09-lineage.ps1` | not started |

## Final Order for `deploy.ps1` (production order)

(Confirm during testing — credentials likely need to land BEFORE sources if registration validates the cred ref at register time.)

## Teardown Order (reverse-ish)

1. Delete data products
2. Delete glossary terms (custom only — don't touch system terms)
3. Delete governance domains
4. Cancel + delete scans
5. Delete data sources
6. Delete credentials
7. Delete managed PEs + managed VNet runtime
8. Unlink Fabric from Purview tenant link? (decide: per-deployment, or leave alone since shared)

## Open Questions

- [ ] Fabric→Purview tenant link: is this safe to toggle off on teardown, or shared infra we don't touch?
- [ ] Managed PE approval: does the SQL/ADLS owner need to approve the PE before scan can run?
- [ ] Do we register the gold warehouse via Fabric data source, or scan it as SQL endpoint?

## Reference

- Purview REST API: https://learn.microsoft.com/en-us/rest/api/purview/
- Atlas API (glossary/lineage): `https://{account}.purview.azure.com/catalog/api/atlas/v2/`
- Scanning API: `https://{account}.purview.azure.com/scan/`
- Account API: `https://{account}.purview.azure.com/account/`
- Unified Catalog (domains/data products): `https://{account}.purview.azure.com/datagovernance/`

## Phase Notes

### Phase 1: Discovery

(Notes go here once we start testing.)

### Phase 2: Fabric Tenant Link

### Phase 3: Networking

### Phase 4: Credentials

### Phase 5: Data Sources

### Phase 6: Scans

### Phase 7: Domains

### Phase 8: Glossary

### Phase 9: Data Products

### Phase 10: Lineage

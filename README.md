# Fabric Data Estate Builder

![Python](https://img.shields.io/badge/Python-3.11+-3776AB?logo=python&logoColor=white)
![FastAPI](https://img.shields.io/badge/FastAPI-009688?logo=fastapi&logoColor=white)
![Bicep](https://img.shields.io/badge/Bicep-3178C6?logo=azurepipelines&logoColor=white)
![Microsoft Fabric](https://img.shields.io/badge/Microsoft%20Fabric-F2F2F2?logo=microsoft&logoColor=black)
![Medallion](https://img.shields.io/badge/Architecture-Medallion-CD7F32)
![License: MIT](https://img.shields.io/badge/License-MIT-50fa7b)

A web app that hands you a one-shot, end-to-end Microsoft Fabric data estate for a fictional company. Pick an industry, configure a few options, download a zip, run `deploy.cmd`. ~20 minutes later (plus ~90 min if you also opt into the Purview governance layer) you have a fully populated bronze / silver / gold medallion in your own Azure subscription with semantic models, Power BI reports, and natural-language data agents on top.

## What gets deployed (Retail vertical)

| Layer | What |
|---|---|
| **Azure** | Resource group, VNet (`10.50.0.0/16`) with delegated gateway subnet + Private Endpoint subnet, Azure SQL Database (serverless Gen5, AAD-only auth, change tracking), SQL Private Endpoint + `privatelink.database.windows.net` zone, ADLS Gen2 (`raw` / `curated`), Azure Functions (Flex Consumption FC1) Python clickstream emitter, Application Insights |
| **Fabric F8 capacity** | VNet Data Gateway + gateway-bound SQL connection (no public network access to SQL by end of deploy) |
| **Bronze workspace** | Lakehouse, SQL Mirror of all retail tables (Delta), OneLake shortcut to ADLS `raw/`, Eventhouse + KQL DB with `Clickstream` table, Eventstream CustomEndpoint, all pipelines (`pl_initial_load`, `pl_incremental_load`, bronze/silver/gold loaders, weather ingest) |
| **Silver workspace** | `silver_raw` lakehouse (shortcuts to all 19 bronze mirror tables) + `silver_curated` lakehouse with five full-load notebooks (retail / weather / clickstream / HR / ops) |
| **Gold workspace** | Warehouse with 9 dims + 9 facts (DROP+CTAS sprocs), `Retail Sales` + `HR & Workforce` Direct Lake semantic models, 4 Power BI reports (Sales Overview, Operations Pulse, HR Workforce, HR Attrition), Fabric Data Agents for natural-language Q&A |
| **Purview governance layer** *(optional)* | Per-deploy scoped collection, MSI RBAC on SQL + ADLS, registered + scanned SQL / ADLS / Fabric sources, two governance domains (`Contoso-Retail`, `Contoso-Retail-HR`), glossary with synonym + related edges, four data products (Sales, Customer 360, Inventory, Workforce) wired to scanned assets + terms + semantic models + reports, OKRs with key results linked to data products, term + DP access policies + auto-generated approval workflows, Critical Data Elements with physical column links, and end-to-end medallion lineage pushed via Atlas |

By the time the script exits, `pl_initial_load` is either running (default) or queued for you to trigger from Fabric. Reports light up in front of you. SQL public network access is disabled and traffic flows over the VNet Data Gateway.

## Architecture at a glance

```
Azure SQL (canonical OLTP) ──┐
ADLS raw/ (Parquet + CSV)    ├──► Bronze workspace (Mirror, shortcuts, KQL)
Function emitter ──► Eventstream CustomEndpoint ──► Eventhouse / KQL DB
                              │
                              ▼
                       Silver workspace (curated dims + facts)
                              │
                              ▼
                       Gold warehouse (star schema, sprocs)
                              │
                              ▼
              Direct Lake semantic models ──► Power BI reports + Data Agents
                              │
                              └──► (optional) Purview catalog scan ──► domains, glossary,
                                   data products, OKRs, CDEs, access policies, Atlas lineage
```

See [docs/medallion-architecture.md](docs/medallion-architecture.md) for the full picture and per-vertical details under [verticals/retail/](verticals/retail/).

## How it works

1. The FastAPI web app (`app/`) renders the vertical's landing page from `verticals/<id>/vertical.yaml`.
2. You hit **Configure Deployment**, set resource group + region + naming prefix, and click **Download Deployment Package**.
3. The server builds a zip containing the vertical's Bicep, PowerShell deploy script, Fabric REST orchestration (`Fabric.ps1`), notebooks, pipelines, semantic models, reports, and a baked `deployment.config` with your settings.
4. You unzip and run `deploy.cmd`. It does `az login`, then deploys Azure infra, creates a service principal for Fabric→SQL mirroring, stands up the VNet Data Gateway + Managed Private Endpoint, builds all three Fabric workspaces, deploys the Function, and (optionally) kicks off `pl_initial_load`.
5. When you're done, `teardown.cmd` reverses everything. The gateway subnet's PowerPlatform service association sometimes takes ~1hr to release, so you may need to re-run `az group delete` once.

Estimated wall-clock for the full Retail deploy: **~20 minutes** for the Azure + Fabric medallion, plus **~90 additional minutes** if you opt into the Purview governance layer (catalog scans + UC entities + lineage).

## Realistic cost

If you pause the Fabric F8 capacity when you're not actively demoing, the whole estate runs around **$25-50/month** (SQL serverless auto-pauses, ADLS / Functions / App Insights are pennies, Private Endpoint is ~$7). If you leave F8 on 24/7, add ~$770/month for the capacity. Run `teardown.cmd` to drop to $0.

The walkthrough modal in the web app has a per-resource price breakdown.

## Optional: Purview governance layer

Check **Deploy Purview governance layer** on the configure page to layer a full Microsoft Purview governance estate on top of the medallion. Requires an existing Purview account in the same subscription that has been upgraded to the new experience (Unified Catalog). The recipe is fully auto-discovering — no Purview account name, no collection name, no source IDs to type in.

The layer is owned by [`verticals/retail/governance/purview/`](verticals/retail/governance/purview/) and runs in two waves around the medallion load:

**Pre-data** (runs in parallel with `pl_initial_load`, because SQL + ADLS are already seeded before the pipelines fire):

1. `00-discover.ps1` — auto-discover the Purview account, retail SQL / ADLS / Fabric workspaces, and persist them to `context.json`.
2. `03-create-collection.ps1` — per-deploy scoped collection so cleanup is surgical.
3. `06-grant-rbac.ps1` — assign Purview MSI the required reader roles on SQL + ADLS.
4. `07-register-sources.ps1` — register Azure SQL DB and ADLS Gen2 as data sources.
5. `08-create-scans.ps1` — create scan definitions targeting the collection.
6. `09-run-scans.ps1` — temporarily flip SQL to public-network for the scan, run, then close it again.
7. `11-governance-domains.ps1` — create `Contoso-Retail` (LOB) + `Contoso-Retail-HR` (FunctionalUnit) governance domains and map the data estate to them.
8. `12-glossary-terms.ps1` — load the retail glossary.
9. `14-term-relationships.ps1` — wire Synonym + Related edges between terms (deduped bidirectionally on teardown).
10. `16-access-policies.ps1` — attach access policies to selected terms.

**Post-data** (must wait for `pl_initial_load` to finish so the Fabric scan finds populated lakehouses; the configure page therefore forces `auto_run_initial_load = true` whenever Purview is checked):

11. `10-fabric-scan.ps1` — trigger a Fabric tenant scan and poll to completion.
12. `13-data-products.ps1` — create four data products (`Sales`, `Customer 360`, `Inventory`, `Workforce`) and link each to its scanned data assets, glossary terms, Direct Lake semantic models, and Power BI reports.
13. `15-okrs.ps1` — create objectives + key results per domain and link them to data products.
14. `17-dp-access-policies.ps1` — attach access policies to each data product and auto-generate the approval workflow.
15. `18-critical-data-elements.ps1` — define CDEs (Customer ID, SKU Number, Store ID, etc.), ingest physical column entities from the Fabric scan, and wire CDE → Term + CDE → DataColumn relationships.
16. `19-lineage.ps1` — push end-to-end Atlas lineage edges (raw → bronze → silver → gold → semantic model) where the Fabric scan didn't already infer them.

Everything is idempotent: re-running `run-all.ps1` (or re-deploying) picks up exactly where it left off. Teardown is handled by `teardown-purview.ps1` (invoked automatically from `teardown.cmd`) and removes everything in dependency order. The recipe does NOT delete the Purview account itself.

**Known gotcha**: the public REST surface currently won't delete a CDE↔DataProduct relationship — both the CDE-side and DP-side `DELETE /relationships` endpoints reject `entityType=DataProduct` / `entityType=CriticalDataElement` respectively, even though `GET` returns the rel from both sides. If teardown leaves orphan CDEs / DPs in a domain, delete them from the Purview portal UI or wait for the API fix to ship (open MS support ticket).

## Run the web app locally

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
uvicorn app.main:app --reload
# Open http://127.0.0.1:8000
```

When only one vertical is marked `available` or `in-progress`, the landing page renders that vertical directly (no picker).

## Project layout

```
app/                       FastAPI web app (UI, package builder, routers)
verticals/
  retail/                  Retail vertical
    vertical.yaml          Metadata (name, description, services, KPIs)
    infra/                 Bicep (network, SQL + PE, storage, function, fabric capacity)
    fabric/                Notebooks, pipelines, lakehouses, semantic models, reports, data agents
    functions/             Python clickstream emitter (Flex Consumption)
    schema/                Azure SQL DDL + JSON event schemas
    governance/
      purview/             Purview integration (19 numbered phases + orchestrator + teardown)
    deploy.ps1             One-shot deploy script
    Fabric.ps1             Fabric REST helpers
    teardown.ps1           Reverses everything in dependency order
docs/                      Architecture notes
```

## Adding a new vertical

1. Create `verticals/<id>/vertical.yaml` with `id`, `name`, `description`, `status`, `azure_services`, `executive_kpis`.
2. Drop in `infra/` (Bicep), `fabric/` (notebook + pipeline + report artifacts), `deploy.ps1`, `teardown.ps1`, `README.md.j2`.
3. Set `status: in-progress` or `available` so it shows up in the web app.

The registry (`app/services/vertical_registry.py`) auto-discovers anything under `verticals/`.

## Status

| Vertical | Status |
|---|---|
| Retail | available (fully deployable end-to-end) |
| Healthcare | not started |
| Finance | not started |
| Manufacturing & Operations | not started |
| Education | not started |

## License

MIT &mdash; see [LICENSE](LICENSE).

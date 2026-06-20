# Healthcare Vertical

Fictional health system "Contoso Health" with a FHIR-first data estate: Azure Health Data Services (FHIR R4) populated with synthetic patients, bulk `$export` into ADLS Gen2, a OneLake shortcut into Microsoft Fabric, and the **Healthcare data solutions in Fabric** medallion (bronze / silver / gold) turning raw FHIR resources into analytics-ready tables.

## What Gets Deployed

- **Azure Health Data Services workspace + FHIR Service (R4)** — managed FHIR store, system-assigned identity for `$export`, Azure-RBAC data plane
- **Azure Data Lake Storage Gen2** — `fhirexport` container (the `$export` landing zone / shortcut source)
- **Microsoft Fabric capacity + workspace** — Healthcare data solutions (bronze / silver / gold lakehouses, FHIR ingestion notebooks + pipelines, semantic models, Power BI reports)
- **OneLake shortcut** — bronze lakehouse → ADLS `fhirexport` container

Infrastructure is provisioned by [deploy.ps1](deploy.ps1) (Bicep under [infra/](infra/)). The full step-by-step is in [RECIPE.md](RECIPE.md).

## Data Flow

```
Baked seed (data/fhir-seed/*.ndjson)
   → seed_fhir.py (REST PUT by id)  → FHIR Service (R4)
   → FHIR $export (NDJSON)          → ADLS fhirexport container
   → OneLake shortcut               → bronze lakehouse (ClinicalFhir)
   → silver flatten                 → one table per FHIR resource type
   → gold / semantic models / Power BI
```

## Synthetic Data

The demo dataset is **pre-generated and committed** to [data/fhir-seed/](data/fhir-seed/) — end users never run Synthea or Java. See [data/README.md](data/README.md).

- **104 FHIR resource types** populate the silver layer (18 from the Synthea base seed, plus 86 minimal-but-valid types synthesized by [data/gen_fhir_extra.py](data/gen_fhir_extra.py) so deployers can validate silver without hunting empty tables).
- Loader: [data/seed_fhir.py](data/seed_fhir.py) — idempotent upsert by id, `--only`, `--workers`, `--dry-run`.
- Regenerating the base seed (maintainers only) is documented in the [RECIPE.md appendix](RECIPE.md).

## Analytics

Executive KPIs (see [vertical.yaml](vertical.yaml)): patient population by age/sex/condition, encounter volume over time, top conditions/procedures/medications, observation trends, cohort segmentation.

## How FHIR data reaches Fabric

This vertical uses **direct `$export` + a manual OneLake shortcut** (deploy.ps1 calls the FHIR `$export` API, then a shortcut surfaces the NDJSON in bronze). This is deliberately simpler than the Microsoft-shipped automation — see below.

### Alternative: the native "Azure Health Data Services – Data export" capability

Healthcare data solutions ships a capability that automates the `$export` via a prebuilt Azure function app driven by the `healthcare#_msft_ahds_fhirservice_export` notebook. **We do not use it** (too many Azure moving parts for a demo), but here is what enabling it would take, for reference:

1. **Prereqs** — Healthcare data foundations installed in the workspace; deployer has **Contributor** + **User Access Administrator** on the Azure subscription.
2. **FHIR service** — an AHDS FHIR R4 service in the **same tenant** as the Fabric workspace.
3. **Deploy the Azure Marketplace offer** "Healthcare data solutions in Microsoft Fabric". This provisions the Azure side: an **export function app**, an **Azure Key Vault**, and storage. Key blade parameters:
   - **Fhir Server Uri** — the FHIR metadata endpoint **minus** `/metadata`.
   - **Export Start Time** — when bulk export begins.
   Then wire RBAC:
   - Enable a **system-assigned managed identity** on the FHIR service.
   - Point the FHIR service's `exportConfiguration.storageAccountName` at the Marketplace storage account, and grant the FHIR MSI **Storage Blob Data Contributor** on it.
   - Grant the export function app **FHIR Data Exporter** on the FHIR service; set its `FHIR Service Uri` + `Export Start Time` app settings.
   - Grant the notebook owner **Key Vault Secrets User**.
4. **Deploy the capability in Fabric** (setup module or capability tile), providing **Azure Key Vault** name and **Maximum polling days** (1–7). This installs the `..._ahds_fhirservice_export` notebook and the `..._clinical_ahds_fhirservice_export` pipeline.
5. **Create the OneLake shortcut** (still required — the capability does **not** remove it) at `Files\External\Clinical\FHIR-NDJSON\AHDS-FHIR\<shortcutname>`, pointing at the Marketplace export container.
6. **Update config** — in the `..._admin` lakehouse, edit `Files/system-configurations/deploymentParametersConfiguration.json` so the `..._fhir_ndjson_bronze_ingestion` activity's `source_path_pattern` points at the shortcut folder:
   `abfss://<workspace_id>@onelake.dfs.fabric.microsoft.com/<bronze_lakehouse_id>/Files/External/Clinical/FHIR-NDJSON/AHDS-FHIR`

> The FHIR URI is configured in **Azure** (the Marketplace function app's `Fhir Server Uri` app setting + the FHIR service's export storage config), **not** in a Fabric config file. The Fabric `deploymentParametersConfiguration.json` only references the Key Vault (`keyvault_name`) and `max_polling_days` for the export activity.

**Net difference vs. our approach:** the capability replaces the manual `$export` REST call with a scheduled function app + notebook, but you still create the same OneLake shortcut. For a demo it adds a function app, a key vault, extra storage, and ~5 RBAC grants — which is why deploy.ps1 does the `$export` directly instead.

Docs:
- [Deploy and configure Azure Health Data Services - Data export](https://learn.microsoft.com/en-us/industry/healthcare/healthcare-data-solutions/ahds-data-export-configure)
- [Overview of Azure Health Data Services - Data export](https://learn.microsoft.com/en-us/industry/healthcare/healthcare-data-solutions/ahds-data-export-overview)
- [Use Azure Health Data Services - Data export](https://learn.microsoft.com/en-us/industry/healthcare/healthcare-data-solutions/ahds-data-export)

## Known fixes

- [fixes/scipy-runtime-repair.md](fixes/scipy-runtime-repair.md) — temporary workaround for the Fabric Runtime 1.3 HDS scipy version skew (remove once the PG fix ships).

# Healthcare vertical — deployment recipe (WORK IN PROGRESS)

> Only **validated, working** steps land here. This file is the source of truth
> for the eventual `deploy.ps1`. Do not add a step until it has been run live in
> the test tenant and confirmed.
>
> Goal of the demo: from a populated FHIR Service to analytics in Microsoft
> Fabric in as few clicks as possible — "nothing to insights."

## Target

- **Region:** `southcentralus` — Azure Health Data Services is **not** available
  in Central US / East US / East US 2. Confirm availability with:
  `az provider show --namespace Microsoft.HealthcareApis --query "resourceTypes[?resourceType=='workspaces'].locations | [0]"`
- **POC resource group:** `rg-contoso-health-poc`
- **Tenant/sub:** test tenant `ME-MngEnvMCAP094505-alexbla-1`
  (`97aba503-25b6-46a2-8ed2-a8afc3bfbd23`)

## Architecture

```
Synthea (synthetic patients, FHIR R4 NDJSON bulk export)
        │  upload NDJSON → fhirimport container
        ▼
ADLS Gen2 (stcontosohealthpoc)  ── fhirimport / fhirexport containers
        │  FHIR $import (IncrementalLoad)
        ▼
Azure Health Data Services workspace ── FHIR Service (R4)
        │  FHIR $export (bulk, NDJSON) → fhirexport container
        ▼
ADLS Gen2 fhirexport
        │  OneLake shortcut
        ▼
Microsoft Fabric — Healthcare data solutions
   bronze (raw FHIR NDJSON) → silver (flattened) → gold (analytics)
        │
        ▼
Semantic models + Power BI reports
```

## Status legend
- ✅ validated live   🔄 in progress   ⬜ not started

---

## Steps

### ✅ 0. Prerequisites
```powershell
az login                                   # Contributor on the subscription
az extension add -n healthcareapis         # FHIR/AHDS CLI commands
az provider show --namespace Microsoft.HealthcareApis --query registrationState -o tsv  # -> Registered
```
- Java (for Synthea): `winget install --id Microsoft.OpenJDK.21 -e` (add `<jdk>\bin` to PATH).

### ✅ 1. Resource group
```powershell
az group create -n rg-contoso-health-poc -l southcentralus
```

### ✅ 2. AHDS workspace (name must be alphanumeric only)
```powershell
az healthcareapis workspace create -g rg-contoso-health-poc -n hdscontosohealth -l southcentralus
```

### ✅ 3. FHIR R4 service (system-assigned identity for export/import)
The default auth config is rejected ("Provided authority is not valid AAD") —
you MUST pass `authority` (tenant login URL) and `audience` (the FHIR URL).
```powershell
$tenant = az account show --query tenantId -o tsv
az healthcareapis workspace fhir-service create `
  -g rg-contoso-health-poc --workspace-name hdscontosohealth --fhir-service-name fhirr4 `
  --kind fhir-R4 -l southcentralus --identity-type SystemAssigned `
  --authentication-configuration `
     authority="https://login.microsoftonline.com/$tenant" `
     audience="https://hdscontosohealth-fhirr4.fhir.azurehealthcareapis.com"
```
- FHIR URL: `https://hdscontosohealth-fhirr4.fhir.azurehealthcareapis.com`
- Capture the service MSI principalId (used for storage RBAC below):
  `az healthcareapis workspace fhir-service show -g rg-contoso-health-poc --workspace-name hdscontosohealth --fhir-service-name fhirr4 --query identity.principalId -o tsv`

### ✅ 4. Grant yourself FHIR data-plane access
AHDS uses Azure RBAC for the data plane (not legacy access policies).
```powershell
$me     = az ad signed-in-user show --query id -o tsv
$fhirId = az healthcareapis workspace fhir-service show -g rg-contoso-health-poc --workspace-name hdscontosohealth --fhir-service-name fhirr4 --query id -o tsv
az role assignment create --assignee $me --role "FHIR Data Contributor" --scope $fhirId
```
Test: `GET {fhir}/Patient?_count=1` with `Authorization: Bearer <token>` where
`token = az account get-access-token --resource {fhir} --query accessToken -o tsv`.

### ✅ 5. ADLS Gen2 storage + import/export containers
Shared-key auth is disabled by default on new accounts — use `--auth-mode login`
for all data-plane calls (and grant yourself the blob data role).
```powershell
az storage account create -n stcontosohealthpoc -g rg-contoso-health-poc -l southcentralus `
  --sku Standard_LRS --kind StorageV2 --enable-hierarchical-namespace true
$sid = az storage account show -n stcontosohealthpoc -g rg-contoso-health-poc --query id -o tsv

# FHIR MSI needs blob data access for BOTH $import and $export
az role assignment create --assignee <fhir-msi-principalId> --role "Storage Blob Data Contributor" --scope $sid
# You need it to upload NDJSON
az role assignment create --assignee $me --role "Storage Blob Data Contributor" --scope $sid

az storage fs create -n fhirimport --account-name stcontosohealthpoc --auth-mode login
az storage fs create -n fhirexport --account-name stcontosohealthpoc --auth-mode login
```

### ✅ 6. Enable $import and $export on the FHIR service
No CLI flags for this — patch the resource properties directly.
```powershell
az resource update --ids $fhirId --api-version 2024-03-31 `
  --set properties.exportConfiguration.storageAccountName=stcontosohealthpoc `
        properties.importConfiguration.integrationDataStore=stcontosohealthpoc `
        properties.importConfiguration.enabled=true `
        properties.importConfiguration.initialImportMode=false
```

### ✅ 7. Generate Synthea data as NDJSON bulk (one file per resource type)
Transaction-bundle POST hits the FHIR service's hard **500-entry per bundle**
limit (Synthea patients routinely exceed it — even with 1 year of history a
single patient was ~1,800 entries), so use **bulk NDJSON + $import** instead. It
has no such limit and is the scalable path.
```powershell
Invoke-WebRequest `
  -Uri 'https://github.com/synthetichealth/synthea/releases/download/master-branch-latest/synthea-with-dependencies.jar' `
  -OutFile synthea-with-dependencies.jar
# bulk_data true => Patient.ndjson, Encounter.ndjson, Observation.ndjson, ... in .\output\fhir\
java -jar synthea-with-dependencies.jar -s 4242 -p 20 `
  --exporter.fhir.bulk_data true --exporter.fhir.use_us_core_ig false Massachusetts
```

### ✅ 8. Upload NDJSON to the import container
```powershell
az storage blob upload-batch --account-name stcontosohealthpoc --auth-mode login `
  -d fhirimport -s .\output\fhir --pattern "*.ndjson" --overwrite
```

### ✅ 9. Run FHIR $import (async)
Build a `Parameters` body: `inputFormat=application/fhir+ndjson`,
`mode=IncrementalLoad`, `storageDetail.type=azure-blob`, and one `input` entry
per blob (`type` = resource type parsed from the filename, `url` = blob URL).
POST to `{fhir}/$import` with header `Prefer: respond-async`; poll the returned
`Content-Location` (`{fhir}/_operations/import/<n>`): **202** = running,
**200** = done (body lists per-type counts and any errors).

Validated result (20 Synthea patients, seed 4242): **0 errors**, e.g.
Patient 21, Encounter 843, Observation 6288, Procedure 2718, Condition 592,
Claim/ExplanationOfBenefit 1449 each, Immunization 340, ...

### ✅ 10. FHIR $export to fhirexport container
Async, RBAC-driven. The FHIR MSI writes NDJSON into the configured storage.
```powershell
# Prefer: respond-async ; _container directs output to a specific container
GET {fhir}/$export?_container=fhirexport
# poll Content-Location {fhir}/_operations/export/<n> : 202 running, 200 done
```
Validated output: one timestamped folder (e.g. `20260617T210901-1/`) with one
NDJSON per resource type — `Patient-…ndjson`, `Observation-…ndjson`,
`Encounter-…ndjson`, `Procedure-…ndjson`, `Condition-…ndjson`,
`DocumentReference`, `Provenance`, `Medication`, `PractitionerRole`, etc.
This folder is the **shortcut source** for Fabric.

---

## Fabric portion — the "~20 clicks: nothing → insights" demo

> NOT yet automated/validated live. Documented from the AHDS + Fabric Healthcare
> data solutions flow. This is the interactive part the demo showcases. Validate
> next, then decide what (if any) is scriptable via the Fabric REST API.

Available Fabric capacity in this sub: `alexblaf64` (**F64**, westus3, RG
`basicresources`). Healthcare data solutions in Fabric needs a beefy capacity —
use the F64.

### ⬜ 11. Fabric workspace + Healthcare data solutions
1. Fabric portal → create a **workspace**, assign it to capacity `alexblaf64` (F64).
2. Workload hub → **Healthcare data solutions** → create a healthcare solution
   in the workspace. It provisions the **bronze / silver / gold lakehouses**,
   ingestion notebooks, and orchestration pipelines.
3. Deploy the **"FHIR data ingestion"** (a.k.a. healthcare data foundations)
   capability into the solution.

### ⬜ 12. OneLake shortcut: fhirexport → bronze "Ingest"
In the solution's **bronze** lakehouse, under the FHIR ingest landing folder,
create an **ADLS Gen2 shortcut**:
- Storage (DFS) endpoint: `https://stcontosohealthpoc.dfs.core.windows.net`
- Container / path: `fhirexport` (point at the timestamped export folder, or the
  container root and let the notebook discover the latest run)
- Auth: organizational account / the workspace identity granted
  `Storage Blob Data Reader` on `stcontosohealthpoc`.

### ⬜ 13. Run the medallion + build reports
1. Run the healthcare ingestion pipeline/notebooks: **bronze** (raw NDJSON) →
   **silver** (FHIR flattened into tabular per-resource tables) → **gold**
   (analytics-ready: patient, encounter, condition, observation marts).
2. Build / open the semantic model and Power BI reports over gold for the
   executive KPIs (population by age/sex/condition, encounter volume, top
   conditions/procedures/meds, observation trends).

---

## Open questions to resolve before writing deploy.ps1
- How much of steps 11–13 is reachable via the Fabric REST API vs. must stay
  manual clicks? (The "nothing → insights in N clicks" story may *want* some of
  it manual.)
- Naming/region: Fabric capacity is in westus3 while AHDS is in southcentralus —
  fine (OneLake shortcut is cross-region), but note the egress.
- Whether to ship Synthea generation in the package (needs Java) or pre-generate
  NDJSON and ship it, or generate inside a Fabric notebook in-tenant.
- Grant the Fabric workspace identity `Storage Blob Data Reader` on the export
  account as part of deploy.

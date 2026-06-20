# Healthcare vertical — deployment recipe (WORK IN PROGRESS)

> Only **validated, working** steps land here. This file is the source of truth
> for the eventual `deploy.ps1`. Do not add a step until it has been run live in
> the test tenant and confirmed.
>
> Goal of the demo: from a populated FHIR Service to analytics in Microsoft
> Fabric in as few clicks as possible — "nothing to insights."

## Target

- **Region:** `westus3` — single region for the whole estate. It must support
  Azure Health Data Services (**not** available in Central US / East US / East
  US 2) **and** have Microsoft Fabric capacity quota. Confirm AHDS availability:
  `az provider show --namespace Microsoft.HealthcareApis --query "resourceTypes[?resourceType=='workspaces'].locations | [0]"`
- **POC resource group:** `rg-contoso-health-poc`
- **Tenant/sub:** test tenant `ME-MngEnvMCAP094505-alexbla-1`
  (`97aba503-25b6-46a2-8ed2-a8afc3bfbd23`)

## Architecture

```
Baked seed (verticals/healthcare/data/fhir-seed/*.ndjson — pre-generated)
        │  seed_fhir.py — REST PUT each resource (no Synthea, no $import)
        ▼
Azure Health Data Services workspace ── FHIR Service (R4)
        │  FHIR $export (bulk, NDJSON) → fhirexport container
        ▼
ADLS Gen2 (stcontosohealthpoc) ── fhirexport
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
- The demo population step needs only Python (stdlib) + `az`. **Java / Synthea
  are not required** — the dataset is baked into the repo. Java is only needed by
  maintainers regenerating the seed (appendix).

### ✅ 1. Resource group
```powershell
az group create -n rg-contoso-health-poc -l westus3
```

### ✅ 2. AHDS workspace (name must be alphanumeric only)
```powershell
az healthcareapis workspace create -g rg-contoso-health-poc -n hdscontosohealth -l westus3
```

### ✅ 3. FHIR R4 service (system-assigned identity for export/import)
The default auth config is rejected ("Provided authority is not valid AAD") —
you MUST pass `authority` (tenant login URL) and `audience` (the FHIR URL).
```powershell
$tenant = az account show --query tenantId -o tsv
az healthcareapis workspace fhir-service create `
  -g rg-contoso-health-poc --workspace-name hdscontosohealth --fhir-service-name fhirr4 `
  --kind fhir-R4 -l westus3 --identity-type SystemAssigned `
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

### ✅ 5. ADLS Gen2 storage + export container
Storage is needed for the **$export → Fabric** side only (population is a direct
PUT, step 7). Shared-key auth is disabled by default on new accounts — use
`--auth-mode login` for all data-plane calls.
```powershell
az storage account create -n stcontosohealthpoc -g rg-contoso-health-poc -l westus3 `
  --sku Standard_LRS --kind StorageV2 --enable-hierarchical-namespace true
$sid = az storage account show -n stcontosohealthpoc -g rg-contoso-health-poc --query id -o tsv

# FHIR MSI needs blob data access to write the $export output
az role assignment create --assignee <fhir-msi-principalId> --role "Storage Blob Data Contributor" --scope $sid

az storage fs create -n fhirexport --account-name stcontosohealthpoc --auth-mode login
```

### ✅ 6. Enable $export on the FHIR service
No CLI flags for this — patch the resource properties directly.
```powershell
az resource update --ids $fhirId --api-version 2024-03-31 `
  --set properties.exportConfiguration.storageAccountName=stcontosohealthpoc
```

### ✅ 7. Populate the FHIR service from the baked seed
The pre-generated dataset ships in `verticals/healthcare/data/fhir-seed/`
(18 clinical resource types, ~13,083 resources for 20 patients). The loader
reads the NDJSON and PUTs each resource straight to the FHIR REST API using your
`az` login — **no storage account, no `$import`, no Synthea/Java**.
```powershell
# needs FHIR Data Contributor (granted in step 4)
python verticals/healthcare/data/seed_fhir.py `
  --fhir-url https://hdscontosohealth-fhirr4.fhir.azurehealthcareapis.com
```
Validated live: **ok=13083 failed=0**. PUT is an idempotent upsert by id, so the
step is safely re-runnable. `--workers N` tunes parallelism (default 8); `--only
Type,Type` seeds a subset; `--dry-run` parses and counts only.

> The seed references practitioners with **literal** `Practitioner/<id>`
> references (normalised from Synthea's conditional `Practitioner?identifier=...`
> form). This matters: a per-resource PUT tries to *resolve* a conditional
> reference at write time, and under concurrency an `Encounter` can be written
> before its `Practitioner` is searchable → HTTP 400. Literal refs skip
> resolution. The normalisation is baked into the committed seed by
> `_normalize_seed.py` (maintainer tool).

### ✅ 8. FHIR $export to fhirexport container
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

### ⬜ 9. Fabric workspace + Healthcare data solutions
1. Fabric portal → create a **workspace**, assign it to capacity `alexblaf64` (F64).
2. Workload hub → **Healthcare data solutions** → create a healthcare solution
   in the workspace. It provisions the **bronze / silver / gold lakehouses**,
   ingestion notebooks, and orchestration pipelines.
3. Deploy the **"FHIR data ingestion"** (a.k.a. healthcare data foundations)
   capability into the solution.

### ⬜ 10. OneLake shortcut: fhirexport → bronze "Ingest"
In the solution's **bronze** lakehouse, under the FHIR ingest landing folder,
create an **ADLS Gen2 shortcut**:
- Storage (DFS) endpoint: `https://stcontosohealthpoc.dfs.core.windows.net`
- Container / path: `fhirexport` (point at the timestamped export folder, or the
  container root and let the notebook discover the latest run)
- Auth: organizational account / the workspace identity granted
  `Storage Blob Data Reader` on `stcontosohealthpoc`.

### ⬜ 11. Run the medallion + build reports
1. Run the healthcare ingestion pipeline/notebooks: **bronze** (raw NDJSON) →
   **silver** (FHIR flattened into tabular per-resource tables) → **gold**
   (analytics-ready: patient, encounter, condition, observation marts).
2. Build / open the semantic model and Power BI reports over gold for the
   executive KPIs (population by age/sex/condition, encounter volume, top
   conditions/procedures/meds, observation trends).

---

## Open questions to resolve before writing deploy.ps1
- How much of steps 9–11 is reachable via the Fabric REST API vs. must stay
  manual clicks? (The "nothing → insights in N clicks" story may *want* some of
  it manual.)
- Naming/region: Fabric capacity, AHDS, and storage all land in westus3 (single
  region), so the OneLake shortcut over the FHIR `$export` stays in-region.
- Grant the Fabric workspace identity `Storage Blob Data Reader` on the export
  account as part of deploy.

---

## Appendix — regenerating the seed (maintainers only)

The demo dataset is **pre-generated and committed** to
`verticals/healthcare/data/fhir-seed/` so end users never run Synthea or Java.
(Decision: ship NDJSON, not the generator.) To regenerate it:

```powershell
# 1. Java + Synthea
winget install --id Microsoft.OpenJDK.21 -e        # add <jdk>\bin to PATH
Invoke-WebRequest -Uri 'https://github.com/synthetichealth/synthea/releases/download/master-branch-latest/synthea-with-dependencies.jar' -OutFile synthea-with-dependencies.jar

# 2. Bulk NDJSON export — one file per resource type (seed 4242, 20 patients)
java -jar synthea-with-dependencies.jar -s 4242 -p 20 `
  --exporter.fhir.bulk_data true --exporter.fhir.use_us_core_ig false Massachusetts

# 3. Copy *.ndjson into fhir-seed/, dropping billing (Claim, ExplanationOfBenefit)
#    and normalising any timestamped filenames (e.g. Location.<ts>.ndjson -> Location.ndjson).

# 4. Normalise conditional references -> literal references (required for PUT)
python verticals/healthcare/data/_normalize_seed.py
```

Why bulk NDJSON (not transaction bundles): a Synthea patient bundle routinely
exceeds the FHIR service's hard **500-entry per bundle** limit (~1,800 entries
for one patient with a year of history), so bundle POST returns HTTP 400. Bulk
NDJSON has no such limit. We originally loaded it via storage + `$import`
(`IncrementalLoad`) — still a valid path — but the shipped demo uses the simpler
self-contained `seed_fhir.py` direct-PUT loader instead.

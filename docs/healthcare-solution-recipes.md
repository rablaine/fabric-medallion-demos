# Healthcare Data Solutions — Validated Run Recipes

Hands-on recipes for lighting up each Microsoft **Healthcare data solutions (HDS)** capability
on top of the **assisted sample-data** deployment, so the sample data flows all the way to
each solution's gold/report layer for a demo.

Every recipe below was **validated end-to-end on a live F8 workspace** (`contoso-health-sampledata`,
HDS instance name `contosohealthcare`) on 2026-06-20/21. Row counts in the **Validate** sections are
the actual numbers observed, not estimates.

> Item names below use the HDS naming pattern `<hdsname>_msft_<marker>`. In the validated environment
> `<hdsname>` = `contosohealthcare`. Item GUIDs differ per deployment — resolve them at run time with
> `GET /v1/workspaces/{workspaceId}/items` and match on `displayName`.

---

## Global rules (learned the hard way)

### 1. Run the clinical-foundation pipelines **sequentially**, never in parallel
The clinical, claims, DICOM-imaging, OMOP, and care-management pipelines all invoke the shared
`bronze_silver_flatten` step and write the **same silver FHIR Delta tables** (Observation, etc.).
Running two of them at once causes a Delta concurrent-write collision.

- **Observed failure:** running `claims` while `clinical` was still ingesting → claims died after
  1h11m with `SilverIngestionFailedError` on the silver `Observation` write. Re-running `claims`
  alone afterward succeeded in **17 min**.
- **Exception:** the **SDOH** pipeline is isolated (writes its own `SocialDeterminant*` tables, not
  the FHIR flatten). It is safe to run alongside the clinical ingestion — validated.

**Order:** `clinical` → then any of `claims` / `OMOP` / `DICOM` (one at a time) → `care management` last.
SDOH may run in parallel with clinical.

### 2. The SQL analytics endpoint **lags** — validate from the Delta log, not `COUNT(*)`
Immediately after a pipeline writes Delta tables, the lakehouse **SQL analytics endpoint** can still
report `COUNT(*) = 0` for minutes (metadata sync lag). This is not a failure.

- **Ground truth:** read the table's `_delta_log/*.json` commits and sum `add.stats.numRecords`
  minus `remove`. Helper: `.scratch/delta-count.ps1` (DFS endpoint, `storage.azure.com` token).
- The SQL-endpoint count is fine for established tables, just not seconds after a write.

### 3. Sample-data staging convention (SampleData → Ingest)
The sample library lives in the **bronze** lakehouse under `Files/SampleData/...`. Solutions read from
`Files/Ingest/...`. Stage with a **server-side OneLake blob copy** (same account = synchronous):
`PUT https://onelake.blob.fabric.microsoft.com/{ws}/{dst}` with header
`x-ms-copy-source: https://onelake.blob.fabric.microsoft.com/{ws}/{src}`.

Path rule: **drop the size-named leaf folder** (`8KCCLFClaims`, `340ImagingStudies`,
`51KSyntheticPatients`); keep the `<SOURCE>-HDS` folder. SDOH mirrors its full tree.

| Domain   | Source (`Files/SampleData/...`)                         | Dest (`Files/Ingest/...`)            |
|----------|---------------------------------------------------------|--------------------------------------|
| Clinical | `Clinical/FHIR-NDJSON/FHIR-HDS/51KSyntheticPatients/*`   | `Clinical/FHIR-NDJSON/FHIR-HDS/*`    |
| Claims   | `Claims/CCLF/CCLF-HDS/8KCCLFClaims/*.T100000x`           | `Claims/CCLF/CCLF-HDS/*.T100000x`    |
| DICOM    | `Imaging/DICOM/DICOM-HDS/340ImagingStudies/*.zip`        | `Imaging/DICOM/DICOM-HDS/*.zip`      |
| SDOH     | `SDOH/**` (CSV + XLSX tree)                              | `SDOH/**` (mirror)                   |

> The assisted sample-data deploy already stages **Clinical** into Ingest. Claims/DICOM/SDOH must be
> staged by the steps above (this is what should be wired into the deploy script).

### 4. Running a pipeline via REST
```
POST /v1/workspaces/{ws}/items/{pipelineId}/jobs/instances?jobType=Pipeline   # 202, Location header
GET  {Location}                                                               # poll .status
```
Terminal states: `Completed` / `Failed` / `Cancelled` / `Deduped`. Token resource:
`https://api.fabric.microsoft.com`. Helpers: `.scratch/hds-lib.ps1`, `run-pipeline.ps1`, `poll-job.ps1`.

---

## 1. Clinical data foundations (prerequisite for everything)

The medallion backbone: FHIR NDJSON → bronze `ClinicalFhir` → silver FHIR R4 resource tables.

- **Prereq:** HDS deployed; clinical sample staged in `Ingest/Clinical/FHIR-NDJSON/FHIR-HDS`
  (done by the assisted sample deploy).
- **Run:** pipeline `*_msft_clinical_data_foundation_ingestion`.
- **Runtime:** ~1h27m on F8 (51K patients, ~42M FHIR records / ~25 GB of NDJSON — the long pole).
- **Validate (silver):**

  | Table | Rows |
  |---|---|
  | `Patient` | 53,054 |
  | `Encounter` | 441,644 |
  | `Condition` | 412,238 |
  | `Observation` | 22,396,683 |
  | `Procedure` | 16,007,150 |
  | `MedicationRequest` | 209,401 |
  | `CarePlan` | 256,318 |
  | bronze `ClinicalFhir` | 42,141,938 |

- **Notes:** `DiagnosticReport` came out 0 in this run (the corresponding NDJSON does not appear to be
  in the staged Ingest subset) — not required by any of the gold solutions below.

---

## 2. CMS claims (CCLF → ExplanationOfBenefit)

CMS Common Claims and Line Feed files → bronze CCLF tables → silver FHIR `ExplanationOfBenefit`.

- **Prereq:** clinical foundations complete. **Stage** claims sample (table above).
- **Run:** pipeline `*_msft_claims_data_ingestion`. **Run alone** (shares the FHIR flatten).
- **Runtime:** ~17 min on F8 (alone).
- **Validate:**

  | Table | Rows |
  |---|---|
  | silver `ExplanationOfBenefit` | 8,632 |
  | bronze `ClaimsCclfHeader` | 8,632 |
  | bronze `ClaimsCclfLineItemDetails` | 59,425 |
  | bronze `ClaimsCclfBeneficiaryDemographicsFile` | 31,190 |

- **Notes:** silver `Claim`/`Coverage` stay 0 — **expected**. CMS CCLF maps to `ExplanationOfBenefit`,
  not the clinical `Claim` resource. One silver EoB per CCLF header row.

---

## 3. SDOH (social determinants of health)

Public SDOH datasets (CSV/XLSX) → bronze `SdohDatasets` → silver `SocialDeterminant`.

- **Prereq:** HDS deployed. **Stage** SDOH sample (mirrors the full `SDOH/**` tree).
- **Run:** pipeline `*_msft_sdoh_ingestion`. **Safe to run in parallel** with clinical (isolated tables).
- **Runtime:** ~21 min on F8.
- **Validate:**

  | Table | Rows |
  |---|---|
  | silver `SocialDeterminant` | 7,811,964 |
  | bronze `SdohDatasets` | 289,332 |
  | silver `SocialDeterminantCategory` | 2 |
  | silver `SocialDeterminantSubCategory` | 7 |

---

## 4. OMOP CDM analytics (gold)

Maps silver FHIR → **OMOP Common Data Model v5.4** in the `gold_omop` lakehouse.

- **Prereq:** clinical foundations complete (silver populated).
- **Run:** pipeline `*_msft_omop_analytics` (drives `*_msft_omop_silver_gold_transformation`). **Alone.**
- **Runtime:** ~27 min on F8.
- **Validate (`gold_omop`):**

  | OMOP table | Rows | Source FHIR |
  |---|---|---|
  | `person` | 53,054 | Patient |
  | `visit_occurrence` | 441,644 | Encounter |
  | `condition_occurrence` | 412,238 | Condition |
  | `procedure_occurrence` | 16,007,150 | Procedure |
  | `drug_exposure` | 209,401 | MedicationRequest |
  | `measurement` | 14,204,832 | Observation (measurement domain) |
  | `observation` | 8,180,275 | Observation (observation domain) |
  | `death` | 8,095 | Patient.deceased |

  `measurement` + `observation` = 22,384,... ≈ silver `Observation` (22.4M), split by OMOP domain. ✔

- **Notes:** `drug_era` / `condition_era` stay 0 here — those are produced by the **optional** sample
  notebooks `*_msft_omop_drug_exposure_era_sample` / `*_msft_omop_drug_exposure_insights_sample`
  (run them for the drug-era histogram demo; params `primary_drug` / `secondary_drug` / `year`).

---

## 5. DICOM imaging

DICOM studies (zipped) → bronze `ImagingDicom` → silver `ImagingStudy` + `ImagingMetastore`.

- **Prereq:** clinical foundations complete. **Stage** the 340-study sample zips (table above).
- **Run:** pipeline `*_msft_imaging_with_clinical_foundation_ingestion`. **Alone.**
- **Runtime:** ~34 min on F8.
- **Validate:**

  | Table | Rows |
  |---|---|
  | bronze `ImagingDicom` | 7,740 |
  | silver `ImagingStudy` | 340 |
  | silver `ImagingMetastore` | 7,740 |

- **Notes:** MS docs cite 7739 / 339 (340 studies minus 1 intentionally-invalid). Observed 7740 / 340 —
  off by one vs the docs, consistent with the sample. Optional: run
  `*_msft_omop_silver_gold_transformation` afterward to populate OMOP `image_occurrence`.

---

## 6. Care management analytics (capstone)

Joins **clinical + claims + SDOH** into the `gold_cma` lakehouse and the `*_msft_cma_report` Power BI
report (pages: Overview, Clinical and Claims, SDoH, Resource Utilization, Diabetes).

- **Prereq:** clinical **and** claims **and** SDOH all complete.
- **Run:** pipeline `*_msft_cma`. **Alone**, last.
- **Runtime:** ~14 min on F8.
- **Validate (`gold_cma`):**

  | Table | Rows | Proves |
  |---|---|---|
  | `person` | 53,054 | clinical |
  | `care_plan` | 256,318 | clinical |
  | `care_plan_activities` | 600,362 | clinical |
  | `condition_occurrence` | 412,238 | clinical |
  | `visit_occurrence` | 441,644 | clinical |
  | `procedure_occurrence` | 16,007,150 | clinical |
  | `measurement` | 14,204,832 | clinical |
  | **`cost`** | **8,632** | **claims integration** (= EoB count) |
  | **`social_determinant`** | **7,811,964** | **SDOH integration** (= SDOH count) |
  | `location` | 53,052 | clinical |

- **Notes:** MS docs warn the **first run may fail by design** on intentional erroneous clinical
  records (just re-run). On this dataset the first run **succeeded** (~14 min). `care_plan_goal` came
  out 0 (minor; does not block the report's main pages). `cost` matching the EoB count and
  `social_determinant` matching the SDOH count is the proof that all three domains fan into CMA.

---

## End-to-end demo sequence (single-capacity, ~3.5 h wall clock on F8)

1. **clinical** (~1h27m) — start first. Start **SDOH** (~21m) in parallel.
2. After clinical: **claims** (~17m) → **OMOP** (~27m) → **DICOM** (~34m), one at a time.
3. **care management** (~14m) last.
4. Validate each via `.scratch/delta-count.ps1` (Delta-log counts), not the SQL endpoint.

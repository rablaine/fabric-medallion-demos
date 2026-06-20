# Healthcare demo seed data

Pre-generated FHIR R4 dataset for the healthcare demo. **End users do not need
Synthea, Java, a storage account, or the FHIR `$import` operation** — the data
is baked into this folder and a small script PUTs it straight into a FHIR
service over REST.

## What's here

- **`fhir-seed/`** — one NDJSON file per FHIR resource type, one resource per
  line. Clinical resources only (billing `Claim` / `ExplanationOfBenefit` were
  intentionally excluded to keep the repo lean). ~13,083 resources across 18
  types for 20 synthetic patients.
- **`seed_fhir.py`** — stdlib-only loader. Reads the NDJSON and PUTs each
  resource to `{fhir}/{resourceType}/{id}` using your `az` login for auth.

| Resource type            | Count |
|--------------------------|------:|
| Observation              |  6288 |
| Procedure                |  2718 |
| Encounter                |   843 |
| DiagnosticReport         |   719 |
| MedicationRequest        |   606 |
| Condition                |   592 |
| SupplyDelivery           |   375 |
| Immunization             |   340 |
| Device                   |   107 |
| ImagingStudy             |    99 |
| MedicationAdministration |    87 |
| Organization             |    78 |
| Practitioner             |    78 |
| CarePlan                 |    56 |
| CareTeam                 |    56 |
| Patient                  |    21 |
| AllergyIntolerance       |    19 |
| Location                 |     1 |

## How it was generated (maintainers only)

Synthea bulk NDJSON export, 20 patients, Massachusetts, seed `4242`:

```powershell
java -jar synthea-with-dependencies.jar -s 4242 -p 20 `
  --exporter.fhir.bulk_data true --exporter.fhir.use_us_core_ig false Massachusetts
```

The `*.ndjson` outputs were copied here (billing resources dropped, timestamped
filenames normalised). Regenerating is **not** part of the demo flow — this
folder is the source of truth.

## Loading into FHIR

```powershell
az login                                  # need FHIR Data Contributor on the service
python seed_fhir.py --fhir-url https://<workspace>-<fhir>.fhir.azurehealthcareapis.com
```

PUT is idempotent (upsert by id), so re-running is safe and will repair any
resources that failed on a previous run. Useful flags:

- `--only Patient,Observation` — seed a subset
- `--workers N` — parallelism (default 8; lower it if you see throttling)
- `--dry-run` — parse + count only, no writes

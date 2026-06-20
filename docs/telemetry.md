# Adoption telemetry

Every deployment-package download is recorded so we can see **how many times
each vertical (environment) was downloaded, with what options, by how many
unique users over time.**

## How it works

- `app/services/telemetry.py` records one `PackageDownloaded` event per download.
- **Opt-in.** Nothing is emitted unless `TELEMETRY_ENABLED=true`. A dev
  environment stays completely silent by default — no App Insights, no local
  file. Only production sets the flag.
- When enabled, two sinks, both best-effort (a telemetry failure never blocks a
  download):
  1. **Local JSONL** — `data/telemetry.jsonl` (gitignored). A durable backstop.
  2. **Application Insights** — the durable, centralized store. Active when
     `APPLICATIONINSIGHTS_CONNECTION_STRING` is also set. Lands in `customEvents`.
- **Shared-resource attribution.** Every event is tagged with a cloud role name
  (`cloud_RoleName` / the `app` dimension), default `fabric-data-estate-builder`,
  so this app is distinguishable from other apps that share the same App
  Insights. Override with `TELEMETRY_ROLE_NAME`.
- Unique users: the download endpoint sets an anonymous `fdeb_uid` cookie
  (random id, no PII). Each event carries `user_id` so we can count distinct
  users without identifying anyone.

Event properties: `vertical`, `location`, `resource_prefix`,
`auto_run_initial_load`, `deploy_purview`, `user_id`, `app`.

## Enable it (production only)

Two app settings turn telemetry on. Leave them **unset** locally so dev never
emits.

```powershell
az webapp config appsettings set -g <rg> -n <app> --settings `
  TELEMETRY_ENABLED=true `
  APPLICATIONINSIGHTS_CONNECTION_STRING="<connection-string>"
```

To test emission locally on purpose, set both in your shell for that session
only:

```powershell
$env:TELEMETRY_ENABLED = "true"
$env:APPLICATIONINSIGHTS_CONNECTION_STRING = (az monitor app-insights component show `
  --app appi-adoption-shared -g rg-telemetry-shared --query connectionString -o tsv)
```


## Configure (centralized in `rg-telemetry-shared`)

| Resource | Name |
|----------|------|
| Resource group | `rg-telemetry-shared` (Central US) |
| Log Analytics | `log-adoption-shared` |
| Application Insights | `appi-adoption-shared` (workspace-based) |

The App Insights resource is shared across apps — filter by the `app` dimension
(`cloud_RoleName`) to isolate this app's events: `app == "fabric-data-estate-builder"`.

Set the connection string on the web app (do **not** commit it):

```powershell
# Local dev (only when you explicitly want to test emission)
$env:TELEMETRY_ENABLED = "true"
$env:APPLICATIONINSIGHTS_CONNECTION_STRING = (az monitor app-insights component show `
  --app appi-adoption-shared -g rg-telemetry-shared --query connectionString -o tsv)

# Azure App Service
az webapp config appsettings set -g <rg> -n <app> --settings `
  TELEMETRY_ENABLED=true `
  APPLICATIONINSIGHTS_CONNECTION_STRING="$env:APPLICATIONINSIGHTS_CONNECTION_STRING"
```

## KQL queries (App Insights → Logs)

> All queries scope to this app via `app == "fabric-data-estate-builder"` because
> the App Insights resource is shared. Adjust the `ago(30d)` window as needed.

**App usage over a period, by vertical + the config options used** (answers
“how much is each vertical used, and with which checkboxes — run-initial-load,
deploy-purview”):

```kql
customEvents
| where name == "PackageDownloaded"
| where timestamp > ago(30d)
| extend app      = tostring(customDimensions.app),
         vertical = tostring(customDimensions.vertical),
         auto_run = tostring(customDimensions.auto_run_initial_load),
         purview  = tostring(customDimensions.deploy_purview),
         user_id  = tostring(customDimensions.user_id)
| where app == "fabric-data-estate-builder"
| summarize downloads = count(), unique_users = dcount(user_id)
        by vertical, auto_run, purview
| order by vertical asc, downloads desc
```

Downloads per vertical:

```kql
customEvents
| where name == "PackageDownloaded"
| extend app = tostring(customDimensions.app), vertical = tostring(customDimensions.vertical)
| where app == "fabric-data-estate-builder"
| summarize downloads = count() by vertical
| order by downloads desc
```

Unique users per vertical over time (weekly):

```kql
customEvents
| where name == "PackageDownloaded"
| extend vertical = tostring(customDimensions.vertical),
         user_id  = tostring(customDimensions.user_id)
| summarize unique_users = dcount(user_id) by vertical, bin(timestamp, 7d)
| order by timestamp asc
```

Most-used options:

```kql
customEvents
| where name == "PackageDownloaded"
| extend app      = tostring(customDimensions.app),
         vertical = tostring(customDimensions.vertical),
         location = tostring(customDimensions.location),
         auto_run = tostring(customDimensions.auto_run_initial_load),
         purview  = tostring(customDimensions.deploy_purview)
| where app == "fabric-data-estate-builder"
| summarize downloads = count() by vertical, location, auto_run, purview
| order by downloads desc
```

Downloads + unique users by day (all verticals):

```kql
customEvents
| where name == "PackageDownloaded"
| extend app = tostring(customDimensions.app), user_id = tostring(customDimensions.user_id)
| where app == "fabric-data-estate-builder"
| summarize downloads = count(), unique_users = dcount(user_id) by bin(timestamp, 1d)
| order by timestamp asc
```

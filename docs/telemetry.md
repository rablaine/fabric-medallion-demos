# Adoption telemetry

Every deployment-package download is recorded so we can see **how many times
each vertical (environment) was downloaded, with what options, by how many
unique users over time.**

## How it works

- `app/services/telemetry.py` records one `PackageDownloaded` event per download.
- Two sinks, both best-effort (a telemetry failure never blocks a download):
  1. **Local JSONL** — `data/telemetry.jsonl` (gitignored). Always on, zero config.
  2. **Application Insights** — the durable, centralized store. Active only when
     `APPLICATIONINSIGHTS_CONNECTION_STRING` is set. Lands in `customEvents`.
- Unique users: the download endpoint sets an anonymous `fdeb_uid` cookie
  (random id, no PII). Each event carries `user_id` so we can count distinct
  users without identifying anyone.

Event properties: `vertical`, `location`, `resource_prefix`,
`auto_run_initial_load`, `deploy_purview`, `user_id`.

## Configure (centralized in `rg-telemetry-shared`)

| Resource | Name |
|----------|------|
| Resource group | `rg-telemetry-shared` (Central US) |
| Log Analytics | `log-adoption-shared` |
| Application Insights | `appi-adoption-shared` (workspace-based) |

Set the connection string on the web app (do **not** commit it):

```powershell
# Local dev
$env:APPLICATIONINSIGHTS_CONNECTION_STRING = (az monitor app-insights component show `
  --app appi-adoption-shared -g rg-telemetry-shared --query connectionString -o tsv)

# Azure App Service
az webapp config appsettings set -g <rg> -n <app> --settings `
  APPLICATIONINSIGHTS_CONNECTION_STRING="$env:APPLICATIONINSIGHTS_CONNECTION_STRING"
```

## KQL queries (App Insights → Logs)

Downloads per vertical:

```kql
customEvents
| where name == "PackageDownloaded"
| extend vertical = tostring(customDimensions.vertical)
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
| extend vertical = tostring(customDimensions.vertical),
         location = tostring(customDimensions.location),
         auto_run = tostring(customDimensions.auto_run_initial_load),
         purview  = tostring(customDimensions.deploy_purview)
| summarize downloads = count() by vertical, location, auto_run, purview
| order by downloads desc
```

Downloads + unique users by day (all verticals):

```kql
customEvents
| where name == "PackageDownloaded"
| extend user_id = tostring(customDimensions.user_id)
| summarize downloads = count(), unique_users = dcount(user_id) by bin(timestamp, 1d)
| order by timestamp asc
```

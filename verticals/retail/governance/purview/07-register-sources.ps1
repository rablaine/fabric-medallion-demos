# Phase 7: register data sources under our collection.
#   - Azure SQL Database (server-scoped registration)
#   - ADLS Gen2 (account-scoped registration)
# Idempotent. Writes back the source names to context.json.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_lib.ps1"
$ctx = Read-Context

$endpoint    = $ctx.purview.endpoint
$collection  = $ctx.collection.name
$suffix      = $ctx.collection.suffix

$sqlSrv = $ctx.retail.sqlServer
$adls   = $ctx.retail.adls

function Ensure-Source {
    param(
        [string]$Name,
        [hashtable]$Properties,
        [string]$Kind
    )
    $url = "$endpoint/scan/datasources/$Name`?api-version=2022-02-01-preview"
    $existing = Invoke-PurviewRest -Method GET -Url $url
    if ($existing) {
        Write-Host "  [exists] $Name (kind=$($existing.kind))" -ForegroundColor DarkGray
        return $existing
    }
    Write-Host "  [create] $Name (kind=$Kind)" -ForegroundColor Cyan
    $body = @{
        name       = $Name
        kind       = $Kind
        properties = $Properties
    }
    $r = Invoke-PurviewRest -Method PUT -Url $url -Body $body
    Write-Host "    created: $($r.name)" -ForegroundColor Green
    return $r
}

# --- SQL ----------------------------------------------------------------------
# Friendly business name (source-type tag shows AzureSqlDatabase under it in portal).
$sqlSourceName = "OrdersDB-$suffix"
Write-Host "=== Register SQL: $sqlSourceName -> $($sqlSrv.fqdn) under '$collection'"
Ensure-Source -Name $sqlSourceName -Kind 'AzureSqlDatabase' -Properties @{
    serverEndpoint = $sqlSrv.fqdn
    location       = (az group show -n $ctx.resourceGroup --query location -o tsv)
    resourceGroup  = $ctx.resourceGroup
    resourceName   = $sqlSrv.name
    resourceId     = $sqlSrv.resourceId
    subscriptionId = $ctx.subscription
    collection     = @{
        type          = 'CollectionReference'
        referenceName = $collection
    }
} | Out-Null

# --- ADLS ---------------------------------------------------------------------
# Friendly business name (source-type tag shows AdlsGen2 under it in portal).
$adlsSourceName = "RawLake-$suffix"
Write-Host ''
Write-Host "=== Register ADLS: $adlsSourceName -> $($adls.dfsEndpoint) under '$collection'"
Ensure-Source -Name $adlsSourceName -Kind 'AdlsGen2' -Properties @{
    endpoint       = $adls.dfsEndpoint
    location       = (az group show -n $ctx.resourceGroup --query location -o tsv)
    resourceGroup  = $ctx.resourceGroup
    resourceName   = $adls.name
    resourceId     = $adls.resourceId
    subscriptionId = $ctx.subscription
    collection     = @{
        type          = 'CollectionReference'
        referenceName = $collection
    }
} | Out-Null

# Persist
$ctxObj = Get-Content "$PSScriptRoot\context.json" -Raw | ConvertFrom-Json
$ctxObj | Add-Member -NotePropertyName dataSources -NotePropertyValue ([ordered]@{
    sql  = $sqlSourceName
    adls = $adlsSourceName
}) -Force
$ctxObj | ConvertTo-Json -Depth 8 | Set-Content -Path "$PSScriptRoot\context.json" -Encoding UTF8

Write-Host ''
Write-Host "Sources registered. Run 08-create-scans.ps1 next." -ForegroundColor Green

# Phase 8: define scans for SQL + ADLS using MSI auth + system rulesets.
# No IR reference => Purview uses the built-in AutoResolveIntegrationRuntime.
# Idempotent. Writes scan names back to context.json.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_lib.ps1"
$ctx = Read-Context

$endpoint   = $ctx.purview.endpoint
$collection = $ctx.collection.name
$suffix     = $ctx.collection.suffix
$sqlSrcName  = $ctx.dataSources.sql
$adlsSrcName = $ctx.dataSources.adls

if (-not $sqlSrcName -or -not $adlsSrcName) { throw "data sources missing - run 07-register-sources.ps1 first" }

function Ensure-Scan {
    param([string]$DataSourceName, [string]$ScanName, [string]$Kind, [hashtable]$Properties)
    $url = "$endpoint/scan/datasources/$DataSourceName/scans/$ScanName`?api-version=2022-02-01-preview"
    $existing = Invoke-PurviewRest -Method GET -Url $url
    if ($existing) {
        Write-Host "  [exists] $ScanName" -ForegroundColor DarkGray
        return $existing
    }
    Write-Host "  [create] $ScanName" -ForegroundColor Cyan
    $r = Invoke-PurviewRest -Method PUT -Url $url -Body @{ name=$ScanName; kind=$Kind; properties=$Properties }
    Write-Host "    created: $($r.name)" -ForegroundColor Green
    return $r
}

$sqlScanName = "scan-sql-contoso_retail-$suffix"
Write-Host "=== Define SQL scan: $sqlScanName"
Ensure-Scan -DataSourceName $sqlSrcName -ScanName $sqlScanName -Kind 'AzureSqlDatabaseMsi' -Properties @{
    scanRulesetName = 'AzureSqlDatabase'
    scanRulesetType = 'System'
    scanScopeType   = 'AutoDetect'
    # enableLineage tries to connect at scan-create time. Always-on private SQL
    # rejects this even though we open public during the scan run itself.
    # Lineage is a separate observability feature; metadata catalog still works.
    enableLineage   = $false
    databaseName    = 'contoso_retail'
    serverEndpoint  = $ctx.retail.sqlServer.fqdn
    collection      = @{ type = 'CollectionReference'; referenceName = $collection }
} | Out-Null

$adlsScanName = "scan-adls-$suffix"
Write-Host ''
Write-Host "=== Define ADLS scan: $adlsScanName"
Ensure-Scan -DataSourceName $adlsSrcName -ScanName $adlsScanName -Kind 'AdlsGen2Msi' -Properties @{
    scanRulesetName = 'AdlsGen2'
    scanRulesetType = 'System'
    scanScopeType   = 'AutoDetect'
    collection      = @{ type = 'CollectionReference'; referenceName = $collection }
} | Out-Null

$ctxObj = Get-Content "$PSScriptRoot\context.json" -Raw | ConvertFrom-Json
$ctxObj | Add-Member -NotePropertyName scans -NotePropertyValue ([ordered]@{
    sql  = $sqlScanName
    adls = $adlsScanName
}) -Force
$ctxObj | ConvertTo-Json -Depth 8 | Set-Content -Path "$PSScriptRoot\context.json" -Encoding UTF8

Write-Host ''
Write-Host "Scans defined (no IR ref => AutoResolveIntegrationRuntime). Run 09-run-scans.ps1 next." -ForegroundColor Green

# Phase 3a: Create scoped collection for this deployment.
# All our data sources/scans go under this collection so teardown is surgical.

[CmdletBinding()]
param(
    [string]$Suffix = '',  # auto-derived from resource group / RG resources if blank
    [string]$ParentCollection = ''  # blank = root
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_lib.ps1"
$ctx = Read-Context
$endpoint = $ctx.purview.endpoint

# Derive suffix from SQL server name (e.g. contoso-retail-sql-datj77 -> datj77)
if (-not $Suffix) {
    if ($ctx.retail.sqlServer.name -match '^contoso-retail-sql-(.+)$') { $Suffix = $matches[1] }
    else { throw "Could not derive suffix; pass -Suffix" }
}

# Purview collection NAMES must be 3-36 chars, alphanumeric+hyphen (no other chars).
# Use a deterministic name from the suffix so re-runs are idempotent.
$collectionName = "contoso-retail-$Suffix"
$friendlyName   = "Contoso Retail ($Suffix)"

Write-Host "=== Phase 3a: ensure collection ===" -ForegroundColor Cyan
Write-Host "Collection name:    $collectionName"
Write-Host "Friendly name:      $friendlyName"
Write-Host "Parent collection:  $(if ($ParentCollection) { $ParentCollection } else { '(root)' })"

# Check if it already exists
$existing = Invoke-PurviewRest -Method GET -Url "$endpoint/account/collections/$collectionName`?api-version=2019-11-01-preview"
if ($existing) {
    Write-Host "  Collection already exists. (idempotent re-run)" -ForegroundColor Green
} else {
    # Resolve parent (default: root)
    if (-not $ParentCollection) {
        $cols = Invoke-PurviewRest -Method GET -Url "$endpoint/account/collections?api-version=2019-11-01-preview"
        $root = ($cols.value | Where-Object { -not $_.parentCollection } | Select-Object -First 1).name
        if (-not $root) { $root = $cols.value[0].name }
        $ParentCollection = $root
    }
    $body = @{
        parentCollection = @{ referenceName = $ParentCollection }
        friendlyName     = $friendlyName
    }
    $created = Invoke-PurviewRest -Method PUT -Url "$endpoint/account/collections/$collectionName`?api-version=2019-11-01-preview" -Body $body
    Write-Host "  Created collection '$($created.name)' under '$ParentCollection'" -ForegroundColor Green
}

# Persist collection name into context so downstream phases use it.
$ctxObj = Get-Content "$PSScriptRoot\context.json" -Raw | ConvertFrom-Json
$ctxObj | Add-Member -NotePropertyName collection -NotePropertyValue ([ordered]@{
    name         = $collectionName
    friendlyName = $friendlyName
    suffix       = $Suffix
}) -Force
$ctxObj | ConvertTo-Json -Depth 8 | Set-Content -Path "$PSScriptRoot\context.json" -Encoding UTF8
Write-Host ''
Write-Host "context.json updated with collection name '$collectionName'" -ForegroundColor Green

# Also persist Purview MSI for downstream RBAC
$msiPrincipalId = (az purview account show -g $ctx.purview.resourceGroup -n $ctx.purview.name --query "identity.principalId" -o tsv)
$ctxObj = Get-Content "$PSScriptRoot\context.json" -Raw | ConvertFrom-Json
$ctxObj.purview | Add-Member -NotePropertyName systemAssignedPrincipalId -NotePropertyValue $msiPrincipalId -Force
$ctxObj | ConvertTo-Json -Depth 8 | Set-Content -Path "$PSScriptRoot\context.json" -Encoding UTF8
Write-Host "Purview SA-MSI principalId saved: $msiPrincipalId" -ForegroundColor Green

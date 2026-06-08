# Auto-discover Purview account, retail SP, Fabric workspaces, ADLS, SQL.
# Idempotent. Run repeatedly. Outputs context.json for downstream phases.

[CmdletBinding()]
param(
    [string]$ResourceGroup = 'rg-contoso-retail-forpurview',
    [string]$OutFile       = "$PSScriptRoot\context.json"
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\_lib.ps1"

Write-Host '=== Discovery ===' -ForegroundColor Cyan

# --- Subscription / tenant context ---
$acct = az account show -o json | ConvertFrom-Json
Write-Host "User:         $($acct.user.name)"
Write-Host "Tenant:       $($acct.tenantId)"
Write-Host "Subscription: $($acct.id) ($($acct.name))"

# --- Purview account (tenant singleton in practice) ---
Write-Host ''
Write-Host 'Purview accounts visible in this subscription:'
$purviewAccounts = az purview account list -o json 2>$null | ConvertFrom-Json
if (-not $purviewAccounts -or $purviewAccounts.Count -eq 0) {
    # Fall back to ARM list across all RGs
    $purviewAccounts = az resource list --resource-type 'Microsoft.Purview/accounts' -o json | ConvertFrom-Json
}
$purviewAccounts | Select-Object name, resourceGroup, location | Format-Table
if (-not $purviewAccounts -or $purviewAccounts.Count -eq 0) {
    throw 'No Purview account found in this subscription. Aborting.'
}
# Singleton assumption: pick the only one. If user has multiples, prompt later.
$purview = $purviewAccounts | Select-Object -First 1
$purviewName     = $purview.name
$purviewRg       = $purview.resourceGroup
$purviewEndpoint = "https://$purviewName.purview.azure.com"
Write-Host "Using Purview: $purviewName (RG=$purviewRg)" -ForegroundColor Green
Write-Host "Endpoint:      $purviewEndpoint"

# --- Retail RG resources ---
Write-Host ''
Write-Host "Retail resources in $ResourceGroup`:"
$resources = az resource list -g $ResourceGroup -o json | ConvertFrom-Json
$resources | Select-Object name, type | Format-Table

$sqlServer  = $resources | Where-Object { $_.type -eq 'Microsoft.Sql/servers' } | Select-Object -First 1
$adls       = $resources | Where-Object { $_.type -eq 'Microsoft.Storage/storageAccounts' } | Select-Object -First 1
$fabricCap  = $resources | Where-Object { $_.type -eq 'Microsoft.Fabric/capacities' } | Select-Object -First 1
$vnet       = $resources | Where-Object { $_.type -eq 'Microsoft.Network/virtualNetworks' } | Select-Object -First 1

# --- SQL details (server FQDN, database list) ---
$sqlInfo = $null
if ($sqlServer) {
    $sqlInfo = az sql server show -g $ResourceGroup -n $sqlServer.name -o json | ConvertFrom-Json
    Write-Host ''
    Write-Host "SQL Server: $($sqlInfo.fullyQualifiedDomainName)" -ForegroundColor Green
    $dbs = az sql db list -g $ResourceGroup -s $sqlServer.name --query "[?name!='master'].name" -o tsv
    Write-Host "  Databases: $($dbs -join ', ')"
}

# --- ADLS details ---
$adlsInfo = $null
if ($adls) {
    $adlsInfo = az storage account show -g $ResourceGroup -n $adls.name -o json | ConvertFrom-Json
    Write-Host ''
    Write-Host "ADLS Account: $($adls.name) (HNS=$($adlsInfo.isHnsEnabled))" -ForegroundColor Green
    Write-Host "  Endpoint: $($adlsInfo.primaryEndpoints.dfs)"
}

# --- Retail SP (look up by app display name pattern) ---
Write-Host ''
$spDisplayPattern = 'sp-fabric-mirror-*'
$sps = az ad sp list --display-name 'sp-fabric-mirror' --query "[?starts_with(displayName, 'sp-fabric-mirror')].{name:displayName, appId:appId, id:id}" -o json | ConvertFrom-Json
$retailSp = $null
if ($sps) {
    # If multiple, prefer the one matching the prefix used in the RG
    $retailSp = $sps | Select-Object -First 1
    Write-Host "Retail SP: $($retailSp.name) (appId=$($retailSp.appId))" -ForegroundColor Green
} else {
    Write-Host "No retail SP found matching '$spDisplayPattern'." -ForegroundColor Yellow
}

# --- Fabric workspaces tied to this deployment (by capacity assignment) ---
$workspaces = @()
if ($fabricCap) {
    $tok = az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv
    $hdr = @{ Authorization = "Bearer $tok" }
    $capId = (Invoke-RestWithRetry -Uri 'https://api.fabric.microsoft.com/v1/capacities' -Headers $hdr).value |
        Where-Object { $_.displayName -eq $fabricCap.name } | Select-Object -ExpandProperty id
    if ($capId) {
        $allWs = (Invoke-RestWithRetry -Uri 'https://api.fabric.microsoft.com/v1/workspaces' -Headers $hdr).value
        $rawWs = $allWs | Where-Object { $_.capacityId -eq $capId }
        Write-Host ''
        Write-Host "Fabric workspaces on capacity '$($fabricCap.name)':" -ForegroundColor Green
        # Enumerate items per workspace so phase 13 can resolve assets by name
        # instead of hard-coded GUIDs (which change on every fresh deploy).
        foreach ($w in $rawWs) {
            $items = @()
            try {
                $items = (Invoke-RestWithRetry -Uri "https://api.fabric.microsoft.com/v1/workspaces/$($w.id)/items" -Headers $hdr).value |
                    Select-Object id, displayName, type
            } catch {
                Write-Host "  ($($w.displayName)) item enumeration failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
            }
            $workspaces += [pscustomobject]@{
                id          = $w.id
                displayName = $w.displayName
                items       = $items
            }
            Write-Host ("  {0,-40} {1,3} items" -f $w.displayName, $items.Count)
        }
    }
}

# --- Persist context ---
$context = [ordered]@{
    discoveredAt    = (Get-Date).ToString('o')
    subscription    = $acct.id
    tenantId        = $acct.tenantId
    user            = $acct.user.name
    resourceGroup   = $ResourceGroup
    purview         = [ordered]@{
        name          = $purviewName
        resourceGroup = $purviewRg
        endpoint      = $purviewEndpoint
    }
    retail = [ordered]@{
        sqlServer  = if ($sqlInfo)  { @{ name = $sqlServer.name; fqdn = $sqlInfo.fullyQualifiedDomainName; resourceId = $sqlServer.id } } else { $null }
        adls       = if ($adlsInfo) { @{ name = $adls.name; dfsEndpoint = $adlsInfo.primaryEndpoints.dfs; resourceId = $adls.id } } else { $null }
        fabricCap  = if ($fabricCap) { @{ name = $fabricCap.name; resourceId = $fabricCap.id } } else { $null }
        vnet       = if ($vnet)      { @{ name = $vnet.name; resourceId = $vnet.id } } else { $null }
        sp         = if ($retailSp)  { @{ name = $retailSp.name; appId = $retailSp.appId; objectId = $retailSp.id } } else { $null }
        workspaces = $workspaces
    }
}

$context | ConvertTo-Json -Depth 8 | Set-Content -Path $OutFile -Encoding UTF8
Write-Host ''
Write-Host "Context written to $OutFile" -ForegroundColor Green

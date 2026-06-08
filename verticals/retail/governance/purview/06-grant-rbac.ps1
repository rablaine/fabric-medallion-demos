# Phase 6: grant Purview managed identity access to data plane resources.
#   - Azure SQL: CREATE USER FROM EXTERNAL PROVIDER + db_datareader on the user database
#   - ADLS Gen2: Storage Blob Data Reader on the storage account
#
# The SQL server has publicNetworkAccess=Disabled. Pattern (mirrored from
# verticals/retail/deploy.ps1): temp-enable PNA + add deployer-IP firewall rule,
# run grant, then revert. We do NOT change the rest of the security posture.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_lib.ps1"
$ctx = Read-Context
$rg          = $ctx.resourceGroup
$sqlServer   = $ctx.retail.sqlServer.name
$sqlServerFqdn = $ctx.retail.sqlServer.fqdn
$adlsId      = $ctx.retail.adls.resourceId
$purviewName = $ctx.purview.name
$purviewOid  = $ctx.purview.systemAssignedPrincipalId

if (-not $purviewOid) { throw "purview.systemAssignedPrincipalId missing in context.json" }

# 1) ADLS: management-plane RBAC, always works ----------------------------------
Write-Host "=== ADLS: grant Storage Blob Data Reader to Purview MSI ==="
$existing = az role assignment list --assignee $purviewOid --scope $adlsId --role "Storage Blob Data Reader" -o json | ConvertFrom-Json
if ($existing -and $existing.Count -gt 0) {
    Write-Host "  already assigned" -ForegroundColor DarkGray
} else {
    az role assignment create --assignee-object-id $purviewOid --assignee-principal-type ServicePrincipal --role "Storage Blob Data Reader" --scope $adlsId --output none
    if ($LASTEXITCODE -ne 0) { throw "Storage Blob Data Reader assignment failed" }
    Write-Host "  granted" -ForegroundColor Green
}

# 2) SQL: contained DB user. Requires SQL data-plane connectivity.
Write-Host ''
Write-Host "=== SQL: CREATE USER + db_datareader on contoso_retail ==="

# Capture current PNA so we can revert.
$pna = az sql server show -g $rg -n $sqlServer --query publicNetworkAccess -o tsv
$pnaWasDisabled = ($pna -eq 'Disabled')
Write-Host "  SQL publicNetworkAccess currently: $pna"

$deployerIp = $null
$firewallRuleName = "AllowPurviewBootstrap-$(Get-Random -Maximum 9999)"
try {
    if ($pnaWasDisabled) {
        Write-Host "  enabling SQL publicNetworkAccess temporarily..." -ForegroundColor Yellow
        az sql server update -g $rg -n $sqlServer --set publicNetworkAccess=Enabled --output none
        if ($LASTEXITCODE -ne 0) { throw "Could not enable publicNetworkAccess" }
    }

    # Always add a fresh deployer-IP firewall rule (idempotent enough since we use a unique name)
    $deployerIp = (Invoke-RestWithRetry -Uri 'https://api.ipify.org?format=json').ip
    Write-Host "  adding firewall rule '$firewallRuleName' for $deployerIp..."
    az sql server firewall-rule create -g $rg -s $sqlServer -n $firewallRuleName --start-ip-address $deployerIp --end-ip-address $deployerIp --output none
    if ($LASTEXITCODE -ne 0) { throw "Firewall rule create failed" }

    # Get SQL token + run CREATE USER on contoso_retail database.
    $sqlToken = (az account get-access-token --resource 'https://database.windows.net/' --output json | ConvertFrom-Json).accessToken
    if (-not $sqlToken) { throw "Could not get SQL access token" }

    # NOTE: For SQL MSI auth, Purview wants the AAD user named after the Purview
    # account ($purviewName). Bind by object id to dodge Graph propagation lag.
    $grantSql = @"
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$purviewName')
    CREATE USER [$purviewName] FROM EXTERNAL PROVIDER WITH OBJECT_ID='$purviewOid';
ALTER ROLE db_datareader ADD MEMBER [$purviewName];
-- Purview also needs view-database-state for schema metadata enumeration.
GRANT VIEW DATABASE STATE TO [$purviewName];
"@
    Write-Host "  running GRANT script on database contoso_retail..."
    $deadline = (Get-Date).AddSeconds(120)
    while ($true) {
        try {
            Invoke-Sqlcmd -ServerInstance $sqlServerFqdn -Database 'contoso_retail' -AccessToken $sqlToken -Query $grantSql -QueryTimeout 60 -ErrorAction Stop
            break
        } catch {
            if ($_.Exception.Message -match 'Principal .* could not be (resolved|found)|not found in the directory|Login failed' -and (Get-Date) -lt $deadline) {
                Write-Host "    propagation lag, retry in 15s..." -ForegroundColor DarkGray
                Start-Sleep -Seconds 15
                continue
            }
            throw
        }
    }
    Write-Host "  Purview MSI granted db_datareader on contoso_retail" -ForegroundColor Green
}
finally {
    # Revert firewall and PNA changes.
    if ($firewallRuleName) {
        Write-Host "  removing firewall rule '$firewallRuleName'..."
        az sql server firewall-rule delete -g $rg -s $sqlServer -n $firewallRuleName --yes 2>$null | Out-Null
    }
    if ($pnaWasDisabled) {
        Write-Host "  restoring SQL publicNetworkAccess=Disabled..."
        az sql server update -g $rg -n $sqlServer --set publicNetworkAccess=Disabled --output none | Out-Null
    }
}

Write-Host ''
Write-Host "RBAC grants complete. Run 07-register-sources.ps1 next." -ForegroundColor Green

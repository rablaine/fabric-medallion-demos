#Requires -Version 7.0
<#
.SYNOPSIS
    Deletes orphan Fabric cloud connections left behind by previous deploy runs.
.DESCRIPTION
    Lists all connections matching contoso_retail_adls (*) and contoso_retail_sql (*).
    Auto-excludes connections whose displayName references a still-live Azure
    resource (storage account or SQL server). Prompts before deleting.
#>
[CmdletBinding()]
param(
    [string[]]$Patterns = @('contoso_retail_adls (*', 'contoso_retail_sql (*', 'contoso_retail_pipelines_wi*', 'contoso_retail_gold_wh (*'),
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

Write-Host "Discovering live Azure resources to preserve..." -ForegroundColor Cyan
$liveStorage = az storage account list --query "[].name" -o tsv | Where-Object { $_ -like 'contoso*' }
$liveSql     = az sql server list      --query "[].name" -o tsv | Where-Object { $_ -like 'contoso*' }
$liveSqlFqdn = $liveSql | ForEach-Object { "$_.database.windows.net" }
Write-Host "  Live storage accounts: $($liveStorage -join ', ')" -ForegroundColor DarkGray
Write-Host "  Live SQL servers:      $($liveSql -join ', ')" -ForegroundColor DarkGray

Write-Host "`nListing Fabric connections..." -ForegroundColor Cyan
$tok = az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv
$hdr = @{ Authorization = "Bearer $tok" }
$all = (Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/connections" -Headers $hdr).value

Write-Host "Discovering live Fabric warehouses (for gold_wh checks)..." -ForegroundColor Cyan
$liveWhIds = @()
try {
    $wsList = (Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/workspaces" -Headers $hdr).value
    foreach ($w in $wsList) {
        try {
            $items = (Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/workspaces/$($w.id)/warehouses" -Headers $hdr).value
            foreach ($it in $items) { $liveWhIds += $it.id }
        } catch { }
    }
} catch { Write-Host "  (warehouse enumeration failed; gold_wh entries will all be marked orphan)" -ForegroundColor DarkYellow }
Write-Host "  Live warehouse GUIDs: $($liveWhIds.Count)" -ForegroundColor DarkGray

$matches = @()
foreach ($pat in $Patterns) { $matches += $all | Where-Object { $_.displayName -like $pat } }
$matches = $matches | Sort-Object id -Unique

if ($matches.Count -eq 0) { Write-Host "No matching connections found." -ForegroundColor Green; return }

$keep = @(); $kill = @()
foreach ($c in $matches) {
    $isLive = $false
    foreach ($s in $liveStorage)  { if ($c.displayName -match [regex]::Escape($s))  { $isLive = $true; break } }
    if (-not $isLive) { foreach ($f in $liveSqlFqdn) { if ($c.displayName -match [regex]::Escape($f)) { $isLive = $true; break } } }
    if (-not $isLive) { foreach ($g in $liveWhIds)   { if ($c.displayName -match [regex]::Escape($g)) { $isLive = $true; break } } }
    if ($isLive) { $keep += $c } else { $kill += $c }
}

Write-Host "`nKeeping ($($keep.Count)) - reference live resources:" -ForegroundColor Green
$keep | Select-Object displayName, id | Format-Table -AutoSize

Write-Host "Will DELETE ($($kill.Count)) - no matching live resource:" -ForegroundColor Yellow
$kill | Select-Object displayName, id | Format-Table -AutoSize

if ($WhatIf) { Write-Host "WhatIf set - exiting without changes." -ForegroundColor DarkYellow; return }
if ($kill.Count -eq 0) { return }

$ans = Read-Host "Type YES to delete the $($kill.Count) orphan connection(s)"
if ($ans -ne 'YES') { Write-Host "Cancelled." -ForegroundColor Yellow; return }

$ok = 0; $fail = 0
foreach ($c in $kill) {
    $attempt = 0; $deleted = $false
    while ($attempt -lt 6 -and -not $deleted) {
        $attempt++
        try {
            Invoke-RestMethod -Method DELETE -Uri "https://api.fabric.microsoft.com/v1/connections/$($c.id)" -Headers $hdr | Out-Null
            Write-Host "  deleted $($c.displayName)" -ForegroundColor Green
            $deleted = $true; $ok++
            Start-Sleep -Milliseconds 750
        } catch {
            $status = $_.Exception.Response.StatusCode.value__
            if ($status -eq 429 -or $status -eq 503) {
                $wait = [Math]::Min(60, [Math]::Pow(2, $attempt))
                Write-Host "    throttled ($status) on $($c.displayName); sleep $wait s (attempt $attempt/6)" -ForegroundColor DarkYellow
                Start-Sleep -Seconds $wait
            } else {
                Write-Host "  FAIL $($c.displayName): $($_.Exception.Message)" -ForegroundColor Red
                $fail++; break
            }
        }
    }
    if (-not $deleted -and $attempt -ge 6) {
        Write-Host "  FAIL $($c.displayName): throttled after 6 retries" -ForegroundColor Red
        $fail++
    }
    Start-Sleep -Milliseconds 400
}
Write-Host "`nDone. deleted=$ok failed=$fail" -ForegroundColor Cyan

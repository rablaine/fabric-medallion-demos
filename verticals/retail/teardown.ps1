# Auto-generated for current dev env (rg-contoso-retail17).
# Tears down EXACTLY the resources this deployment created.
#Requires -Version 7.0
$ErrorActionPreference = 'Stop'

$ResourceGroup = 'rg-contoso-retail17'
$Subscription  = '97aba503-25b6-46a2-8ed2-a8afc3bfbd23'
$CapacityName  = 'contosoretailrlhevcj2'
$Workspaces = @(
    @{ Id = '3b8596bb-b5b0-4620-b6b6-a3c2a7b2b66c'; Name = 'contoso-retail-1-bronze-rlhevcj2' }
)

. (Join-Path $PSScriptRoot 'scripts\Fabric.ps1')

Write-Host ''
Write-Host 'About to PERMANENTLY DELETE:' -ForegroundColor Yellow
Write-Host "  Resource group: $ResourceGroup (subscription $Subscription)"
Write-Host "  Capacity:       $CapacityName"
Write-Host '  Fabric workspaces:'
foreach ($w in $Workspaces) { Write-Host "    - $($w.Name) ($($w.Id))" }
Write-Host ''
$ans = Read-Host 'Type YES to proceed'
if ($ans -ne 'YES') { Write-Host 'Cancelled.'; exit 0 }

az account set --subscription $Subscription | Out-Null

Write-Host 'Deleting Fabric workspaces...' -ForegroundColor Cyan
$fabToken = (az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv)
foreach ($w in $Workspaces) {
    try {
        Invoke-FabricRest -Token $fabToken -Method DELETE -Path "/workspaces/$($w.Id)" | Out-Null
        Write-Host "  deleted $($w.Name)" -ForegroundColor Green
    } catch {
        Write-Host "  skip $($w.Name): $_" -ForegroundColor DarkYellow
    }
}

Write-Host 'Deleting resource group (async)...' -ForegroundColor Cyan
az group delete --name $ResourceGroup --yes --no-wait

Write-Host ''
Write-Host 'Teardown initiated. Resource group deletion runs in the background.' -ForegroundColor Green
Read-Host 'Press Enter to exit'

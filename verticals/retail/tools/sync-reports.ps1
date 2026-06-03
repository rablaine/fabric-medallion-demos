# sync-reports.ps1
# -----------------------------------------------------------------------------
# Sync the four PBIR-Legacy reports against the live environment. Idempotent.
# Run from a deployment dir that has scripts/Fabric.ps1 + fabric/reports/.
#
#   pwsh -File .\tools\sync-reports.ps1
#
# Discovers the gold workspace, looks up the Retail Sales + HR & Workforce
# semantic model ids, then deploys each report wired to its model via
# byConnection (semanticmodelid=<guid>).
# -----------------------------------------------------------------------------

[CmdletBinding()]
param(
    [string]$DeploymentRoot = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'

if ((Split-Path -Leaf $DeploymentRoot) -eq 'tools') {
    $DeploymentRoot = Split-Path -Parent $DeploymentRoot
}

. (Join-Path (Join-Path $DeploymentRoot 'scripts') 'Fabric.ps1')

$tok = Get-FabricToken
$ws = (Invoke-FabricRest -Token $tok -Method GET -Path '/workspaces').Body.value `
    | Where-Object { $_.displayName -like 'cts-rtl-3-gold-*' } `
    | Select-Object -First 1
if (-not $ws) { throw "No workspace matching cts-rtl-3-gold-* found" }
$goldWsId = $ws.id
Write-Host "Gold ws: $($ws.displayName) ($goldWsId)" -ForegroundColor Cyan

$sm = (Invoke-FabricRest -Token $tok -Method GET -Path "/workspaces/$goldWsId/semanticModels").Body.value
$smRetail = $sm | Where-Object { $_.displayName -eq 'Retail Sales'    } | Select-Object -First 1
$smHr     = $sm | Where-Object { $_.displayName -eq 'HR & Workforce' } | Select-Object -First 1
if (-not $smRetail) { throw "'Retail Sales' semantic model not found"    }
if (-not $smHr)     { throw "'HR & Workforce' semantic model not found" }
Write-Host "  Retail Sales   $($smRetail.id)" -ForegroundColor Cyan
Write-Host "  HR & Workforce $($smHr.id)"    -ForegroundColor Cyan

$reportsRoot = Join-Path $DeploymentRoot 'fabric' 'reports'
$reports = @(
    @{ slug='rpt_sales_overview';   name='Retail - Sales Overview';     smId=$smRetail.id }
    @{ slug='rpt_sales_operations'; name='Retail - Operations';         smId=$smRetail.id }
    @{ slug='rpt_hr_workforce';     name='HR - Workforce Overview';     smId=$smHr.id     }
    @{ slug='rpt_hr_attrition';     name='HR - Attrition & Tenure';     smId=$smHr.id     }
)

foreach ($r in $reports) {
    Write-Host ""
    Write-Host "Deploying report '$($r.name)'" -ForegroundColor Cyan
    $rep = New-FabricReport `
        -Token $tok `
        -WorkspaceId $goldWsId `
        -Name $r.name `
        -DefinitionRoot (Join-Path $reportsRoot $r.slug) `
        -Replacements @{ '__SEMANTIC_MODEL_ID__' = $r.smId }
    Write-Host "  id=$($rep.id)" -ForegroundColor Green
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green

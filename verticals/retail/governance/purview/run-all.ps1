# Orchestrator: runs every Purview phase in dependency order.
# Idempotent end-to-end: re-running picks up exactly where it left off.
#
# Skips cleanly (exit 0, no error) when no Purview account is found in the
# subscription — Purview is not currently provisioned by the vertical's bicep,
# it's expected to pre-exist as a tenant-level resource.
#
# Invoked from deploy.ps1 with -ResourceGroup. Can also be run standalone.
#
# Mode controls which phases run:
#   All      (default) — every phase end-to-end. Use this standalone or when
#                        you don't care about parallelism with the medallion load.
#   PreData              — everything safe to run BEFORE the Fabric lakehouses
#                        are populated. SQL + ADLS scans are included because
#                        their source data already exists from seed. Lets
#                        deploy.ps1 do useful Purview work in parallel with
#                        pl_initial_load.
#   PostData             — Fabric scan + everything that references Fabric assets
#                        or data products. Must run after pl_initial_load finishes
#                        so the Fabric scan finds populated lakehouses/warehouses.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [ValidateSet('All','PreData','PostData')][string]$Mode = 'All',
    [int]$ScanTimeoutMinutes  = 30,
    [int]$FabricTimeoutMinutes = 45,
    [switch]$SkipScans  # for fast iteration on the governance side without re-scanning
)

$ErrorActionPreference = 'Stop'

# Preflight: is there a Purview account in this subscription at all?
$purviewAccounts = az purview account list -o json 2>$null | ConvertFrom-Json
if (-not $purviewAccounts -or $purviewAccounts.Count -eq 0) {
    # ARM fallback in case purview ext is not installed
    $purviewAccounts = az resource list --resource-type 'Microsoft.Purview/accounts' -o json 2>$null | ConvertFrom-Json
}
if (-not $purviewAccounts -or $purviewAccounts.Count -eq 0) {
    Write-Host "  [skip] No Purview account in subscription. Purview governance skipped." -ForegroundColor Yellow
    Write-Host "         (Provision a Purview account at the tenant level to enable governance on re-deploy.)" -ForegroundColor DarkGray
    return
}

# Pre-data phases. Safe to run in parallel with pl_initial_load — SQL/ADLS data
# is already populated by the seed notebook (which runs during the deploy script
# itself, BEFORE pl_initial_load), so 09's scans find their source data even if
# the Fabric medallion is still building.
$preDataPhases = @(
    @{ Script = '00-discover.ps1';              Args = @{ ResourceGroup = $ResourceGroup }; Label = 'Discover Purview + retail resources' },
    @{ Script = '03-create-collection.ps1';     Args = @{};                                  Label = 'Create scoped collection' },
    @{ Script = '06-grant-rbac.ps1';            Args = @{};                                  Label = 'Grant Purview MSI to SQL + ADLS' },
    @{ Script = '07-register-sources.ps1';      Args = @{};                                  Label = 'Register SQL + ADLS sources' },
    @{ Script = '08-create-scans.ps1';          Args = @{};                                  Label = 'Create SQL + ADLS scans' }
)
if (-not $SkipScans) {
    $preDataPhases += @{ Script = '09-run-scans.ps1'; Args = @{ TimeoutMinutes = $ScanTimeoutMinutes }; Label = 'Run SQL + ADLS scans (temp public flip)' }
}
$preDataPhases += @(
    @{ Script = '11-governance-domains.ps1';     Args = @{}; Label = 'Governance domains + data estate mapping' },
    @{ Script = '12-glossary-terms.ps1';         Args = @{}; Label = 'Glossary terms' },
    @{ Script = '14-term-relationships.ps1';     Args = @{}; Label = 'Term synonym + related relationships' },
    @{ Script = '16-access-policies.ps1';        Args = @{}; Label = 'Term access policies' }
)

# Post-data phases. Phase 10 (Fabric scan) needs the lakehouses populated. 13
# (data products) wires `fabric_*` and `powerbi_dataset` assets that only exist
# after 10. 15 (OKRs) and 17 (DP access policies) depend on the DPs from 13. 18
# (CDEs + column links) walks columns surfaced by 10's Fabric scan.
$postDataPhases = @()
if (-not $SkipScans) {
    $postDataPhases += @{ Script = '10-fabric-scan.ps1'; Args = @{ TimeoutMinutes = $FabricTimeoutMinutes }; Label = 'Fabric tenant scan' }
}
$postDataPhases += @(
    @{ Script = '13-data-products.ps1';          Args = @{}; Label = 'Data products' },
    @{ Script = '15-okrs.ps1';                   Args = @{}; Label = 'OKRs (objectives + key results)' },
    @{ Script = '17-dp-access-policies.ps1';     Args = @{}; Label = 'Data product access policies + workflows' },
    @{ Script = '18-critical-data-elements.ps1'; Args = @{}; Label = 'Critical Data Elements + column links' }
)

$phases = switch ($Mode) {
    'PreData'  { $preDataPhases }
    'PostData' { $postDataPhases }
    default    { $preDataPhases + $postDataPhases }
}

foreach ($p in $phases) {
    Write-Host ""
    Write-Host "--- $($p.Label) ($($p.Script)) ---" -ForegroundColor Cyan
    $splat = $p.Args
    & (Join-Path $PSScriptRoot $p.Script) @splat
}

Write-Host ""
Write-Host "Purview governance phase '$Mode' complete." -ForegroundColor Green

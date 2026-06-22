# ===========================================================================
# HdsSolutions.ps1  —  Detect, stage, and run Healthcare data solutions on the
# assisted sample-data flow.
#
# Dot-sourced by deploy-sampledata.ps1 AFTER Fabric.ps1 and the OneLake
# data-plane helpers. These functions resolve their dependencies at call time:
#   - Fabric.ps1:            Get-FabricToken, Invoke-FabricRest
#   - deploy-sampledata.ps1: Get-FabricItems, Get-OneLakeStorageToken,
#                            Get-OneLakePaths, Copy-OneLakeBlob
#
# Background / source of truth: docs/healthcare-solution-recipes.md. Every
# Healthcare data solution shows up in the workspace as a pipeline named
# `<hdsname>_msft_<marker>`. The sample dataset ships under the bronze lakehouse
# at Files/SampleData/...; solutions read from Files/Ingest/..., so each domain
# is staged with a server-side OneLake blob copy before its pipeline runs.
#
# Run order is dependency-safe (recipe "Global rules"): clinical first (the
# shared FHIR flatten), SDOH may run alongside it (isolated tables), then
# claims / OMOP / DICOM one at a time, then care-management last.
# ===========================================================================

function Get-HdsSolutionCatalog {
    <#
    .SYNOPSIS
        The solutions the assisted sample-data flow can detect and assist with.
        `Stage` is $null when the solution reads existing silver/gold tables and
        needs no raw sample staging (OMOP, care management). `DropSizeLeaf`
        strips the size-named sample folder (e.g. 8KCCLFClaims / 340ImagingStudies)
        so files land directly under the Ingest <SOURCE>-HDS folder; SDOH mirrors
        its full tree.
    #>
    @(
        [pscustomobject]@{
            Key = 'clinical'; DisplayName = 'Clinical data foundations'; EstMinutes = 87
            PipelineMarker = '_msft_clinical_data_foundation_ingestion'
            Stage = $null   # staged separately (curated resource-type subset) before this runs
            DependsOn = @()
        }
        [pscustomobject]@{
            Key = 'sdoh'; DisplayName = 'Social determinants of health'; EstMinutes = 21
            PipelineMarker = '_msft_sdoh_ingestion'
            Stage = [pscustomobject]@{ SampleSubPath = 'SDOH'; IngestSubPath = 'SDOH'; DropSizeLeaf = $false }
            DependsOn = @()
        }
        [pscustomobject]@{
            Key = 'claims'; DisplayName = 'CMS claims'; EstMinutes = 17
            PipelineMarker = '_msft_claims_data_ingestion'
            Stage = [pscustomobject]@{ SampleSubPath = 'Claims/CCLF/CCLF-HDS'; IngestSubPath = 'Claims/CCLF/CCLF-HDS'; DropSizeLeaf = $true }
            DependsOn = @('clinical')
        }
        [pscustomobject]@{
            Key = 'omop'; DisplayName = 'OMOP common data model'; EstMinutes = 27
            PipelineMarker = '_msft_omop_analytics'
            Stage = $null   # maps existing silver FHIR -> gold_omop, no raw staging
            DependsOn = @('clinical')
        }
        [pscustomobject]@{
            Key = 'dicom'; DisplayName = 'DICOM imaging'; EstMinutes = 34
            PipelineMarker = '_msft_imaging_with_clinical_foundation_ingestion'
            Stage = [pscustomobject]@{ SampleSubPath = 'Imaging/DICOM/DICOM-HDS'; IngestSubPath = 'Imaging/DICOM/DICOM-HDS'; DropSizeLeaf = $true }
            DependsOn = @('clinical')
        }
        [pscustomobject]@{
            Key = 'cma'; DisplayName = 'Care management analytics'; EstMinutes = 14
            PipelineMarker = '_msft_cma$'   # anchored so it doesn't catch _msft_cma_report etc.
            Stage = $null   # joins existing clinical + claims + SDOH into gold_cma
            DependsOn = @('clinical', 'claims', 'sdoh')
        }
    )
}

function Get-DeployedHdsSolutions {
    <#
    .SYNOPSIS
        Returns the catalog entries whose pipeline is present in the workspace,
        with the matched pipeline item attached as a `Pipeline` note property.
        This is the "detect deployed solutions" step.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array] $Items
    )
    $deployed = [System.Collections.Generic.List[object]]::new()
    foreach ($s in (Get-HdsSolutionCatalog)) {
        $pipe = $Items | Where-Object { $_.type -eq 'DataPipeline' -and $_.displayName -match $s.PipelineMarker } | Select-Object -First 1
        if ($pipe) {
            $s | Add-Member -NotePropertyName Pipeline -NotePropertyValue $pipe -Force
            $deployed.Add($s)
        }
    }
    return $deployed.ToArray()
}

function Get-HdsWallClockEstimate {
    <#
    .SYNOPSIS
        Approximate wall-clock minutes to run the given solutions in dependency
        order: clinical + claims + OMOP + DICOM + care management run one at a
        time (summed); SDOH overlaps clinical so it only adds time if it would
        outlast clinical (it doesn't) or if clinical isn't present.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][array] $Solutions)
    $byKey = @{}
    foreach ($s in $Solutions) { $byKey[$s.Key] = $s }
    $clinicalMin = if ($byKey.ContainsKey('clinical')) { [int]$byKey['clinical'].EstMinutes } else { 0 }
    $total = $clinicalMin
    if ($byKey.ContainsKey('sdoh')) {
        $sd = [int]$byKey['sdoh'].EstMinutes
        if (-not $byKey.ContainsKey('clinical')) { $total += $sd }
        elseif ($sd -gt $clinicalMin) { $total += ($sd - $clinicalMin) }
    }
    foreach ($k in @('claims', 'omop', 'dicom')) { if ($byKey.ContainsKey($k)) { $total += [int]$byKey[$k].EstMinutes } }
    if ($byKey.ContainsKey('cma')) { $total += [int]$byKey['cma'].EstMinutes }
    return $total
}

function Write-HdsRuntimeHeadsUp {
    <#
    .SYNOPSIS
        Prints a clear "this takes hours, that's expected" heads-up with the
        per-solution validated runtimes (F8) and an estimated wall-clock total,
        so the operator trusts the deployer while it polls long-running jobs.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][array] $Solutions)
    $byKey = @{}
    foreach ($s in $Solutions) { $byKey[$s.Key] = $s }
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "  HEADS-UP: ingestion pipelines run for a WHILE. This is normal" -ForegroundColor Cyan
    Write-Host "  - the deployer polls each job to completion, it is NOT stuck." -ForegroundColor Cyan
    Write-Host "  Validated runtimes on an F8 capacity:" -ForegroundColor Cyan
    foreach ($s in $Solutions) {
        $note = ''
        if ($s.Key -eq 'clinical') { $note = '  <- the long pole (~25 GB of NDJSON)' }
        elseif ($s.Key -eq 'sdoh' -and $byKey.ContainsKey('clinical')) { $note = '  <- overlaps clinical, no added wait' }
        Write-Host ("    - {0,-32} ~{1,3} min{2}" -f $s.DisplayName, $s.EstMinutes, $note) -ForegroundColor Cyan
    }
    $wall = Get-HdsWallClockEstimate -Solutions $Solutions
    $h = [math]::Floor($wall / 60); $m = $wall % 60
    Write-Host ("  Estimated wall-clock total: ~{0}h{1:00}m on F8 (pipelines run one" -f $h, $m) -ForegroundColor Cyan
    Write-Host "  at a time except SDOH). Go grab a coffee - leave this window open." -ForegroundColor Cyan
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Invoke-HdsDomainStaging {
    <#
    .SYNOPSIS
        Server-side OneLake copy of one domain's sample files from
        Files/SampleData/<SampleSubPath> to Files/Ingest/<IngestSubPath>.
        DropSizeLeaf strips the first path segment under the sample root (the
        size-named folder). Returns the count of files copied.
    #>
    param(
        [Parameter(Mandatory)][string] $StorageToken,
        [Parameter(Mandatory)][string] $WorkspaceId,
        [Parameter(Mandatory)][string] $BronzeId,
        [Parameter(Mandatory)][object] $Spec,
        [Parameter(Mandatory)][string] $Label
    )
    $sampleRoot = "$BronzeId/Files/SampleData/$($Spec.SampleSubPath)"
    $prefix     = "$sampleRoot/"
    $paths      = Get-OneLakePaths -Token $StorageToken -WorkspaceId $WorkspaceId -Directory $sampleRoot -Recursive $true
    $files = @($paths | Where-Object {
        $isDir = $false
        if ($_.PSObject.Properties.Name -contains 'isDirectory') { $isDir = ($_.isDirectory -eq $true -or $_.isDirectory -eq 'true') }
        -not $isDir
    })
    if ($files.Count -eq 0) {
        Write-Host "    [!] $Label - no sample files found under Files/SampleData/$($Spec.SampleSubPath); skipping." -ForegroundColor Yellow
        Write-Host "        (Make sure the 'Sample data' box was checked in the foundations wizard.)" -ForegroundColor Yellow
        return 0
    }

    $ok = 0; $fail = 0
    foreach ($f in $files) {
        if (-not $f.name.StartsWith($prefix)) { continue }
        $rel = $f.name.Substring($prefix.Length)
        if ($Spec.DropSizeLeaf) {
            $slash = $rel.IndexOf('/')
            if ($slash -ge 0) { $rel = $rel.Substring($slash + 1) }   # drop the size-named leaf folder
        }
        $dest = "$BronzeId/Files/Ingest/$($Spec.IngestSubPath)/$rel"
        try {
            Copy-OneLakeBlob -Token $StorageToken -WorkspaceId $WorkspaceId -SourcePath $f.name -DestPath $dest | Out-Null
            $ok++
        }
        catch {
            Write-Host ("    [FAIL] {0}  {1}" -f $rel, $_.Exception.Message) -ForegroundColor Yellow
            $fail++
        }
    }
    Write-Host ("    $Label - staged {0} file(s) into Ingest/$($Spec.IngestSubPath) ({1} failed)." -f $ok, $fail) -ForegroundColor Green
    return $ok
}

function Invoke-HdsSampleStaging {
    <#
    .SYNOPSIS
        Stages sample data for every detected solution that needs it (clinical /
        OMOP / care-management have no raw staging). Best-effort: a missing or
        empty sample tree warns and continues.
    #>
    param(
        [Parameter(Mandatory)][string] $WorkspaceId,
        [Parameter(Mandatory)][string] $BronzeId,
        [Parameter(Mandatory)][AllowEmptyCollection()][array] $Solutions
    )
    $toStage = @($Solutions | Where-Object { $_.Stage })
    if ($toStage.Count -eq 0) {
        Write-Host "  No additional solutions need sample staging." -ForegroundColor DarkGray
        return
    }
    $stok = Get-OneLakeStorageToken
    foreach ($s in $toStage) {
        Write-Host "  staging sample data for $($s.DisplayName)..."
        Invoke-HdsDomainStaging -StorageToken $stok -WorkspaceId $WorkspaceId -BronzeId $BronzeId -Spec $s.Stage -Label $s.DisplayName | Out-Null
    }
}

function Start-HdsPipeline {
    <#
    .SYNOPSIS
        Kicks off a pipeline (POST jobs/instances) and returns the job-instance
        URL (the 202 Location) for polling, or $null on a non-success start.
    #>
    param(
        [Parameter(Mandatory)][string] $WorkspaceId,
        [Parameter(Mandatory)][object] $Pipeline
    )
    $tok = Get-FabricToken
    $r = Invoke-FabricRest -Token $tok -Method POST `
        -Path "/workspaces/$WorkspaceId/items/$($Pipeline.id)/jobs/instances?jobType=Pipeline"
    if ($r.Status -in 200, 201, 202) {
        Write-Host "     started '$($Pipeline.displayName)' (HTTP $($r.Status))." -ForegroundColor Green
        return $r.OperationLocation
    }
    Write-Host "     [!] '$($Pipeline.displayName)' start returned HTTP $($r.Status)." -ForegroundColor Yellow
    return $null
}

function Wait-HdsPipelineJob {
    <#
    .SYNOPSIS
        Polls a pipeline job-instance URL until it reaches a terminal state.
        Terminal states (Fabric): Completed / Failed / Cancelled / Deduped.
        Re-acquires the token each poll so long runs survive token expiry.
        Returns $true only on Completed.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()][string] $JobUrl,
        [string] $Label = 'pipeline',
        [int] $TimeoutSec = 18000,
        [int] $PollSec = 60
    )
    if (-not $JobUrl) {
        Write-Host "     [!] $Label - no job URL to poll (start may have failed); not waiting." -ForegroundColor Yellow
        return $false
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        Start-Sleep -Seconds $PollSec
        $st = $null
        try { $st = (Invoke-FabricRest -Token (Get-FabricToken) -Method GET -Path $JobUrl).Body.status } catch {}
        if ($st -eq 'Completed') {
            Write-Host ("     [OK] {0} completed (after {1:hh\:mm\:ss})." -f $Label, $sw.Elapsed) -ForegroundColor Green
            return $true
        }
        if ($st -in 'Failed', 'Cancelled', 'Deduped') {
            Write-Host ("     [!] {0} ended in '{1}' (after {2:hh\:mm\:ss}). See the pipeline run in Fabric." -f $Label, $st, $sw.Elapsed) -ForegroundColor Yellow
            return $false
        }
        Write-Host ("     ... {0}: {1}; {2:hh\:mm\:ss} elapsed, checking again in {3}s..." -f $Label, $(if ($st) { $st } else { 'InProgress' }), $sw.Elapsed, $PollSec) -ForegroundColor DarkGray
    }
    Write-Host ("     [!] {0} still running after {1:hh\:mm\:ss}; giving up the wait (it keeps running in Fabric)." -f $Label, $sw.Elapsed) -ForegroundColor Yellow
    return $false
}

function Invoke-HdsPipelineOrchestration {
    <#
    .SYNOPSIS
        Runs the detected solutions' pipelines in dependency-safe order:
          1. kick SDOH (isolated, runs alongside clinical)
          2. run clinical, wait (the long pole; the shared FHIR flatten)
          3. wait for SDOH
          4. run claims / OMOP / DICOM one at a time (shared flatten -> no overlap)
          5. run care-management last (needs clinical + claims + SDOH)
        Only solutions present in $Solutions are touched.
    #>
    param(
        [Parameter(Mandatory)][string] $WorkspaceId,
        [Parameter(Mandatory)][AllowEmptyCollection()][array] $Solutions
    )
    $byKey = @{}
    foreach ($s in $Solutions) { $byKey[$s.Key] = $s }

    if ($Solutions.Count -eq 0) {
        Write-Host "  [!] No Healthcare data solutions detected in the workspace - nothing to run." -ForegroundColor Yellow
        Write-Host "      Deploy at least Data Foundations (clinical), then rerun this script." -ForegroundColor Yellow
        return
    }
    Write-Host ("  detected: {0}" -f (($Solutions | ForEach-Object { $_.DisplayName }) -join ', ')) -ForegroundColor Cyan

    # 1. SDOH first, non-blocking (isolated tables, safe alongside clinical).
    $sdohJob = $null
    if ($byKey.ContainsKey('sdoh')) {
        Write-Host "  -> SDOH ingestion (runs in parallel with clinical)..."
        $sdohJob = Start-HdsPipeline -WorkspaceId $WorkspaceId -Pipeline $byKey['sdoh'].Pipeline
    }

    # 2. Clinical foundation - the prerequisite for everything else. Wait for it.
    $clinicalOk = $false
    if ($byKey.ContainsKey('clinical')) {
        Write-Host "  -> clinical data foundation ingestion (the long pole, ~1.5 h on F8)..."
        $job = Start-HdsPipeline -WorkspaceId $WorkspaceId -Pipeline $byKey['clinical'].Pipeline
        $clinicalOk = Wait-HdsPipelineJob -JobUrl $job -Label 'clinical'
    }
    else {
        Write-Host "  [!] No clinical pipeline detected; clinical-dependent solutions will be skipped." -ForegroundColor Yellow
    }

    # 3. Collect SDOH (usually long done by now during clinical's run).
    if ($sdohJob) { Wait-HdsPipelineJob -JobUrl $sdohJob -Label 'SDOH' | Out-Null }

    # 4. Clinical-dependent solutions, strictly one at a time (shared flatten).
    foreach ($key in @('claims', 'omop', 'dicom')) {
        if (-not $byKey.ContainsKey($key)) { continue }
        $s = $byKey[$key]
        if (-not $clinicalOk) {
            Write-Host "  [!] Skipping $($s.DisplayName) - clinical did not complete." -ForegroundColor Yellow
            continue
        }
        Write-Host "  -> $($s.DisplayName) ingestion..."
        $job = Start-HdsPipeline -WorkspaceId $WorkspaceId -Pipeline $s.Pipeline
        Wait-HdsPipelineJob -JobUrl $job -Label $s.DisplayName | Out-Null
    }

    # 5. Care management last - needs clinical + claims + SDOH all present.
    if ($byKey.ContainsKey('cma')) {
        $missing = @($byKey['cma'].DependsOn | Where-Object { -not $byKey.ContainsKey($_) })
        if (-not $clinicalOk) {
            Write-Host "  [!] Skipping care management - clinical did not complete." -ForegroundColor Yellow
        }
        elseif ($missing.Count -gt 0) {
            Write-Host ("  [!] Skipping care management - missing dependency solutions: {0}." -f ($missing -join ', ')) -ForegroundColor Yellow
        }
        else {
            Write-Host "  -> care management analytics (capstone)..."
            $job = Start-HdsPipeline -WorkspaceId $WorkspaceId -Pipeline $byKey['cma'].Pipeline
            Wait-HdsPipelineJob -JobUrl $job -Label 'care management' | Out-Null
        }
    }

    Write-Host "  all detected solution pipelines have been processed." -ForegroundColor Green
}

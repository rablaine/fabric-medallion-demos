# 19-lineage.ps1 — wire end-to-end medallion lineage into Purview Atlas
# Run after the Fabric scan (10-fabric-scan.ps1) has populated discovered assets.
#
# Builds lineage:
#   Azure SQL tables --> [SQL Mirror Process] --> contoso_retail_sql_mirror lake_warehouse
#   external weather API --> ingest_weather notebook --> contoso_retail_bronze lakehouse
#   pl_bronze_weather_ingest --> contoso_retail_bronze (wraps ingest_weather)
#   Function App event hub --> [clickstream_es Process] --> contoso_retail_events kusto
#   01_seed_clickstream_backfill --> contoso_retail_events
#   mirror --> silver_curated_retail_full / silver_curated_hr_full --> silver_curated lakehouse
#   bronze --> silver_curated_weather_full --> silver_curated
#   kusto --> silver_curated_clickstream_full --> silver_curated
#   2 ADLS resource sets --> silver_curated_ops_full --> silver_curated
#   pl_silver_initial_load / pl_silver_incremental_load --> orchestrator over above
#   silver_curated --> _refresh_silver_curated_sep notebook --> silver_curated lake_warehouse (SEP)
#   silver_curated (lakehouse + lake_warehouse) --> pl_gold_initial_load / pl_gold_incremental_load --> contoso_retail_gold warehouse
#   contoso_retail_gold --> [Gold to Semantic Model Process] --> Retail Sales + HR & Workforce datasets
#   (datasets --> reports already auto-wired by Power BI scan)

. "$PSScriptRoot\_lib.ps1"
$ctx = Read-Context
$base = $ctx.purview.endpoint
$script:h = @{ Authorization = "Bearer $(Get-PurviewToken)"; 'Content-Type' = 'application/json' }

function Write-Step($m) { Write-Host "`n>> $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "  OK  $m" -ForegroundColor Green }
function Write-Skip($m) { Write-Host "  --  $m" -ForegroundColor DarkGray }
function Write-Warn2($m){ Write-Host "  !!  $m" -ForegroundColor Yellow }

function Find-EntityByQN {
    param([string]$Qn, [string]$TypeName)
    $body = @{ keywords = $Qn; limit = 5; filter = @{ entityType = $TypeName } } | ConvertTo-Json -Depth 10
    $r = Invoke-RestMethod -Method Post -Uri "$base/datamap/api/search/query?api-version=2023-09-01" -Headers $script:h -Body $body
    return ($r.value | Where-Object qualifiedName -eq $Qn | Select-Object -First 1)
}

function Get-AzureSqlTableGuids {
    param([string]$SqlServerFqdn, [string]$Database, [string]$Schema)
    $prefix = "mssql://$SqlServerFqdn/$Database/$Schema/"
    $body = @{ keywords = $SqlServerFqdn; limit = 500; filter = @{ entityType = 'azure_sql_table' } } | ConvertTo-Json -Depth 10
    $r = Invoke-RestMethod -Method Post -Uri "$base/datamap/api/search/query?api-version=2023-09-01" -Headers $script:h -Body $body
    return $r.value | Where-Object { $_.qualifiedName.StartsWith($prefix) -and ($_.qualifiedName.Split('/').Count -eq ($prefix.Split('/').Count)) }
}

function Get-AdlsResourceSetGuids {
    param([string]$DfsEndpoint)
    # match: https://<account>.dfs.core.windows.net/...
    $accountHost = ([uri]$DfsEndpoint).Host
    $body = @{ keywords = $accountHost; limit = 500; filter = @{ entityType = 'azure_datalake_gen2_resource_set' } } | ConvertTo-Json -Depth 10
    $r = Invoke-RestMethod -Method Post -Uri "$base/datamap/api/search/query?api-version=2023-09-01" -Headers $script:h -Body $body
    return $r.value | Where-Object qualifiedName -match "^https://$accountHost/"
}

# ------------- resolve asset GUIDs from context.json -------------
Write-Step "Resolving asset GUIDs from context.json + Purview catalog"
$assets = @{}

# helper: build Purview QN for Fabric artifact
function Fabric-Qn { param($Ws, $Kind, $Id) "https://app.fabric.microsoft.com/groups/$Ws/$Kind/$Id" }
function Pbi-Qn    { param($Ws, $Kind, $Id) "https://app.powerbi.com/groups/$Ws/$Kind/$Id" }

# map Fabric item type -> qualifiedName "kind" segment + Atlas type name
$kindMap = @{
    Lakehouse        = @{ Segment='lakehouses';        Type='fabric_lakehouse' }
    SQLEndpoint      = @{ Segment='lakewarehouses';    Type='fabric_lake_warehouse' }
    Warehouse        = @{ Segment='datawarehouses';    Type='fabric_data_warehouse' }
    MirroredDatabase = @{ Segment='lakewarehouses';    Type='fabric_lake_warehouse' }
    Notebook         = @{ Segment='synapsenotebooks';  Type='fabric_synapse_notebook' }
    DataPipeline     = @{ Segment='pipelines';         Type='fabric_pipeline' }
    KQLDatabase      = @{ Segment='databases';         Type='fabric_kusto_database' }
    Eventhouse       = $null  # eventhouse parent — not the data container; the KQLDatabase is
    Eventstream      = $null  # no Atlas type
    SemanticModel    = @{ Segment='datasets';          Type='powerbi_dataset'; UsePbi=$true }
    Report           = @{ Segment='reports';           Type='powerbi_report';  UsePbi=$true }
    DataAgent        = $null  # not in Atlas
}

foreach ($ws in $ctx.retail.workspaces) {
    foreach ($it in $ws.items) {
        $k = $kindMap[$it.type]
        if ($null -eq $k) { continue }
        $qn = if ($k.UsePbi) { Pbi-Qn $ws.id $k.Segment $it.id } else { Fabric-Qn $ws.id $k.Segment $it.id }
        # Workspace-scoped key: <ws-displayname>/<item-displayname>
        $key = "$($it.type):$($ws.displayName -replace '.*-(\d)-(\w+)-.*','$2'):$($it.displayName)"
        $assets[$key] = @{ Qn = $qn; TypeName = $k.Type; ItemId = $it.id; WsId = $ws.id; DisplayName = $it.displayName; ItemType = $it.type }
    }
}

# Resolve guids in batch from Purview
Write-Host "  resolving $($assets.Count) asset GUIDs..." -ForegroundColor DarkGray
foreach ($k in @($assets.Keys)) {
    $a = $assets[$k]
    $found = Find-EntityByQN -Qn $a.Qn -TypeName $a.TypeName
    if ($found) {
        $assets[$k].Guid = $found.id
    } else {
        Write-Warn2 "no GUID for $k  ($($a.Qn))"
    }
}
$assets.GetEnumerator() | Sort-Object Key | ForEach-Object {
    $marker = if ($_.Value.Guid) { 'O' } else { 'X' }
    "    [$marker] $($_.Key)  guid=$($_.Value.Guid)"
} | Out-Null  # silent on success

# ---- SQL tables and ADLS resource sets ----
Write-Step "Resolving Azure SQL tables + ADLS resource sets"
$sqlTables = Get-AzureSqlTableGuids -SqlServerFqdn $ctx.retail.sqlServer.fqdn -Database 'contoso_retail' -Schema 'retail'
"  sql tables: $($sqlTables.Count)"
$sqlTables | Sort-Object name | ForEach-Object { "    $($_.name)  guid=$($_.id)" }

$adlsSets = Get-AdlsResourceSetGuids -DfsEndpoint $ctx.retail.adls.dfsEndpoint
"  adls resource sets: $($adlsSets.Count)"
$adlsSets | ForEach-Object { "    $($_.name)  guid=$($_.id)" }

# ---- shortcut accessor ----
function Get-Asset { param([string]$Key) $assets[$Key] }
function As-Ref { param($Asset) @{ guid = $Asset.Guid; typeName = $Asset.TypeName } }
function As-RefRaw { param($Guid, $TypeName) @{ guid = $Guid; typeName = $TypeName } }

# Build refs once
$bronzeLh   = Get-Asset 'Lakehouse:bronze:contoso_retail_bronze'
$silverCur  = Get-Asset 'Lakehouse:silver:contoso_retail_silver_curated'      # primary in silver ws
$silverRaw  = Get-Asset 'Lakehouse:silver:contoso_retail_silver_raw'
$silverCurSep = Get-Asset 'SQLEndpoint:silver:contoso_retail_silver_curated'  # SEP
$mirrorLw   = Get-Asset 'SQLEndpoint:bronze:contoso_retail_sql_mirror'        # mirror SEP
$kusto      = Get-Asset 'KQLDatabase:bronze:contoso_retail_events'
$goldWh     = Get-Asset 'Warehouse:gold:contoso_retail_gold'
$dsSales    = Get-Asset 'SemanticModel:gold:Retail Sales'
$dsHr       = Get-Asset 'SemanticModel:gold:HR & Workforce'

# Pipelines
$plBronzeInit   = Get-Asset 'DataPipeline:bronze:pl_bronze_initial_load'
$plBronzeIncr   = Get-Asset 'DataPipeline:bronze:pl_bronze_incremental_load'
$plBronzeWeath  = Get-Asset 'DataPipeline:bronze:pl_bronze_weather_ingest'
$plSilverInit   = Get-Asset 'DataPipeline:bronze:pl_silver_initial_load'
$plSilverIncr   = Get-Asset 'DataPipeline:bronze:pl_silver_incremental_load'
$plGoldInit     = Get-Asset 'DataPipeline:bronze:pl_gold_initial_load'
$plGoldIncr     = Get-Asset 'DataPipeline:bronze:pl_gold_incremental_load'
$plInit         = Get-Asset 'DataPipeline:bronze:pl_initial_load'
$plIncr         = Get-Asset 'DataPipeline:bronze:pl_incremental_load'

# Notebooks
$nbIngestWeather = Get-Asset 'Notebook:bronze:ingest_weather'
$nbClickseed     = Get-Asset 'Notebook:bronze:01_seed_clickstream_backfill'
$nbSilverRetail  = Get-Asset 'Notebook:silver:silver_curated_retail_full'
$nbSilverHr      = Get-Asset 'Notebook:silver:silver_curated_hr_full'
$nbSilverWeather = Get-Asset 'Notebook:silver:silver_curated_weather_full'
$nbSilverClick   = Get-Asset 'Notebook:silver:silver_curated_clickstream_full'
$nbSilverOps     = Get-Asset 'Notebook:silver:silver_curated_ops_full'
$nbRefreshSep    = Get-Asset 'Notebook:silver:_refresh_silver_curated_sep'

# Verify everything we need
$required = @{
    bronzeLh=$bronzeLh; silverCur=$silverCur; silverCurSep=$silverCurSep; mirrorLw=$mirrorLw; kusto=$kusto; goldWh=$goldWh
    dsSales=$dsSales; dsHr=$dsHr
    plBronzeInit=$plBronzeInit; plBronzeIncr=$plBronzeIncr; plBronzeWeath=$plBronzeWeath
    plSilverInit=$plSilverInit; plSilverIncr=$plSilverIncr; plGoldInit=$plGoldInit; plGoldIncr=$plGoldIncr
    nbIngestWeather=$nbIngestWeather; nbClickseed=$nbClickseed
    nbSilverRetail=$nbSilverRetail; nbSilverHr=$nbSilverHr; nbSilverWeather=$nbSilverWeather
    nbSilverClick=$nbSilverClick; nbSilverOps=$nbSilverOps; nbRefreshSep=$nbRefreshSep
}
$missing = $required.GetEnumerator() | Where-Object { -not $_.Value -or -not $_.Value.Guid }
if ($missing) {
    Write-Warn2 "Missing assets:"
    $missing | ForEach-Object { "    $($_.Key)" }
    Write-Warn2 "Continuing with what we have..."
}

# ------------- upsert Process-type entities with their inputs/outputs -------------
function Upsert-ProcessLineage {
    param([string]$Label, $ProcessAsset, [array]$Inputs, [array]$Outputs)
    if (-not $ProcessAsset -or -not $ProcessAsset.Guid) { Write-Skip "$Label (process missing)"; return }
    $ins  = @($Inputs  | Where-Object { $_ -and $_.Guid })
    $outs = @($Outputs | Where-Object { $_ -and $_.Guid })
    if (-not $ins -and -not $outs) { Write-Skip "$Label (no valid endpoints)"; return }
    $body = @{
        entity = @{
            guid       = $ProcessAsset.Guid
            typeName   = $ProcessAsset.TypeName
            attributes = @{ qualifiedName = $ProcessAsset.Qn; name = $ProcessAsset.DisplayName }
            relationshipAttributes = @{
                inputs  = @($ins  | ForEach-Object { As-Ref $_ })
                outputs = @($outs | ForEach-Object { As-Ref $_ })
            }
        }
    }
    try {
        $r = Invoke-RestMethod -Method Post -Uri "$base/datamap/api/atlas/v2/entity" -Headers $script:h -Body ($body | ConvertTo-Json -Depth 20)
        Write-Ok "$Label  in=$($ins.Count) out=$($outs.Count)"
    } catch {
        Write-Warn2 "$Label upsert failed: $($_.Exception.Message)"
        try { "    body: $($_.ErrorDetails.Message)" } catch {}
    }
}

# Custom Process entity (e.g. SQL mirror, eventstream) - typeName='Process'
function Upsert-CustomProcess {
    param([string]$Label, [string]$Qn, [string]$Name, [array]$Inputs, [array]$Outputs)
    $ins  = @($Inputs  | Where-Object { $_ -and $_.Guid })
    $outs = @($Outputs | Where-Object { $_ -and $_.Guid })
    if (-not $ins -and -not $outs) { Write-Skip "$Label (no endpoints)"; return }
    $body = @{
        entity = @{
            typeName   = 'Process'
            attributes = @{ qualifiedName = $Qn; name = $Name }
            relationshipAttributes = @{
                inputs  = @($ins  | ForEach-Object { As-Ref $_ })
                outputs = @($outs | ForEach-Object { As-Ref $_ })
            }
        }
    }
    try {
        $r = Invoke-RestMethod -Method Post -Uri "$base/datamap/api/atlas/v2/entity" -Headers $script:h -Body ($body | ConvertTo-Json -Depth 20)
        Write-Ok "$Label  in=$($ins.Count) out=$($outs.Count)"
    } catch {
        Write-Warn2 "$Label upsert failed: $($_.Exception.Message)"
        try { "    body: $($_.ErrorDetails.Message)" } catch {}
    }
}

# wrap a raw search-result row as an "asset" hashtable for the helpers
function As-AssetFromSearch {
    param($Row, [string]$DefaultType)
    $t = if ($Row.entityType) { $Row.entityType } else { $DefaultType }
    @{ Guid = $Row.id; Qn = $Row.qualifiedName; TypeName = $t; DisplayName = $Row.name }
}
$sqlTableAssets  = $sqlTables | ForEach-Object { As-AssetFromSearch -Row $_ -DefaultType 'azure_sql_table' }
$adlsSetAssets   = $adlsSets  | ForEach-Object { As-AssetFromSearch -Row $_ -DefaultType 'azure_datalake_gen2_resource_set' }

# ------------- the lineage spec -------------
Write-Step "Wiring lineage edges"

# 1) SQL -> mirror (custom Process)
$mirrorProcessQn = "process://contoso_retail/sql-mirror/$($ctx.collection.suffix)"
Upsert-CustomProcess -Label 'SQL Mirror (Azure SQL -> contoso_retail_sql_mirror)' `
    -Qn $mirrorProcessQn -Name "SQL Mirror ($($ctx.retail.sqlServer.name))" `
    -Inputs $sqlTableAssets -Outputs @($mirrorLw)

# 2) pl_bronze_weather_ingest -> bronze (wraps ingest_weather)
Upsert-ProcessLineage -Label 'pl_bronze_weather_ingest -> bronze' `
    -ProcessAsset $plBronzeWeath -Inputs @() -Outputs @($bronzeLh)

# 2b) ingest_weather notebook (the actual writer) -> bronze
Upsert-ProcessLineage -Label 'ingest_weather notebook -> bronze' `
    -ProcessAsset $nbIngestWeather -Inputs @() -Outputs @($bronzeLh)

# 3) clickstream_es eventstream -> kusto (custom Process - no Atlas type for eventstream)
$clickProcessQn = "process://contoso_retail/clickstream-es/$($ctx.collection.suffix)"
Upsert-CustomProcess -Label 'Clickstream Eventstream -> events kusto' `
    -Qn $clickProcessQn -Name 'Clickstream Eventstream (Event Hub -> contoso_retail_events)' `
    -Inputs @() -Outputs @($kusto)

# 3b) seed notebook also writes to kusto
Upsert-ProcessLineage -Label '01_seed_clickstream_backfill -> kusto' `
    -ProcessAsset $nbClickseed -Inputs @() -Outputs @($kusto)

# 4) bronze pipelines - no direct SQL read; mirror feeds these implicitly. Skipping their per-source edges
# (the SQL Mirror Process handles SQL -> mirror; the silver notebooks read from mirror)
# Still wire weather/orchestrators where useful.

# 5) silver curated notebooks (bronze | mirror | kusto | adls) -> silver_curated
Upsert-ProcessLineage -Label 'silver_curated_retail_full (mirror -> silver_curated)' `
    -ProcessAsset $nbSilverRetail -Inputs @($mirrorLw) -Outputs @($silverCur)

Upsert-ProcessLineage -Label 'silver_curated_hr_full (mirror -> silver_curated)' `
    -ProcessAsset $nbSilverHr -Inputs @($mirrorLw) -Outputs @($silverCur)

Upsert-ProcessLineage -Label 'silver_curated_weather_full (bronze -> silver_curated)' `
    -ProcessAsset $nbSilverWeather -Inputs @($bronzeLh) -Outputs @($silverCur)

Upsert-ProcessLineage -Label 'silver_curated_clickstream_full (kusto -> silver_curated)' `
    -ProcessAsset $nbSilverClick -Inputs @($kusto) -Outputs @($silverCur)

Upsert-ProcessLineage -Label 'silver_curated_ops_full (adls -> silver_curated)' `
    -ProcessAsset $nbSilverOps -Inputs $adlsSetAssets -Outputs @($silverCur)

# 6) silver pipelines orchestrators
$silverOrchestratorInputs = @($mirrorLw, $bronzeLh, $kusto) + $adlsSetAssets
Upsert-ProcessLineage -Label 'pl_silver_initial_load orchestrator' `
    -ProcessAsset $plSilverInit -Inputs $silverOrchestratorInputs -Outputs @($silverCur)

Upsert-ProcessLineage -Label 'pl_silver_incremental_load orchestrator' `
    -ProcessAsset $plSilverIncr -Inputs $silverOrchestratorInputs -Outputs @($silverCur)

# 7) _refresh_silver_curated_sep -> SEP
Upsert-ProcessLineage -Label '_refresh_silver_curated_sep' `
    -ProcessAsset $nbRefreshSep -Inputs @($silverCur) -Outputs @($silverCurSep)

# 8) gold pipelines (silver_curated -> gold warehouse via stored procs)
Upsert-ProcessLineage -Label 'pl_gold_initial_load (silver_curated -> gold)' `
    -ProcessAsset $plGoldInit -Inputs @($silverCur, $silverCurSep) -Outputs @($goldWh)

Upsert-ProcessLineage -Label 'pl_gold_incremental_load (silver_curated -> gold)' `
    -ProcessAsset $plGoldIncr -Inputs @($silverCur, $silverCurSep) -Outputs @($goldWh)

# 9) master orchestrators (pl_initial_load / pl_incremental_load)
$masterInputs = @($mirrorLw, $bronzeLh, $kusto) + $adlsSetAssets
Upsert-ProcessLineage -Label 'pl_initial_load (master)' `
    -ProcessAsset $plInit -Inputs $masterInputs -Outputs @($goldWh)

Upsert-ProcessLineage -Label 'pl_incremental_load (master)' `
    -ProcessAsset $plIncr -Inputs $masterInputs -Outputs @($goldWh)

# 10) gold -> semantic models (custom Process per dataset)
$dsLoadSalesQn = "process://contoso_retail/gold-to-semantic/$($ctx.collection.suffix)/retail-sales"
Upsert-CustomProcess -Label 'gold -> Retail Sales semantic model' `
    -Qn $dsLoadSalesQn -Name 'Retail Sales semantic model load' `
    -Inputs @($goldWh) -Outputs @($dsSales)

$dsLoadHrQn = "process://contoso_retail/gold-to-semantic/$($ctx.collection.suffix)/hr-workforce"
Upsert-CustomProcess -Label 'gold -> HR & Workforce semantic model' `
    -Qn $dsLoadHrQn -Name 'HR & Workforce semantic model load' `
    -Inputs @($goldWh) -Outputs @($dsHr)

Write-Host "`nDone. Lineage edges wired. Open Purview UI > Data Catalog > any asset > Lineage tab to view." -ForegroundColor Cyan

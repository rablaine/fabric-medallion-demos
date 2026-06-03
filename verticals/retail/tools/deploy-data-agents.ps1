# deploy-data-agents.ps1
# -----------------------------------------------------------------------------
# Create a DataAgent in the gold workspace for each semantic model.
# Builds the agent definition (.platform + Files/Config/...) from the semantic
# model's model.bim (lineageTags become element ids), base64-packages it, and
# POSTs as a new Fabric item.
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

# -----------------------------------------------------------------------------
# Map measure name -> data_type hint (the agent uses this as a column-type hint
# for query planning; column data_types come from TMDL directly).
# -----------------------------------------------------------------------------
function Get-MeasureDataType {
    param([string]$Name)
    if ($Name -match '%')              { return 'Double' }
    if ($Name -match 'Salary|Payroll|Sales|Revenue|Amount|Price|Cost|Discount|Tax|Shipping') { return 'Decimal' }
    if ($Name -match 'Avg|Rate|Ratio|Tenure|Rolling') { return 'Double' }
    return 'Int64'
}

function ConvertTo-AgentDataType {
    param([string]$TmslType)
    switch ($TmslType) {
        'int64'    { 'Int64' }
        'string'   { 'String' }
        'boolean'  { 'Boolean' }
        'dateTime' { 'DateTime' }
        'decimal'  { 'Decimal' }
        'double'   { 'Double' }
        default    { 'String' }
    }
}

function Get-SemanticModelDefinition {
    param([string]$Token, [string]$WorkspaceId, [string]$ModelId)
    $r = Invoke-FabricRest -Token $Token -Method POST -Path "/workspaces/$WorkspaceId/semanticModels/$ModelId/getDefinition?format=TMSL"
    if ($r.OperationLocation) {
        Wait-FabricOperation -Token $Token -OperationLocation $r.OperationLocation -Label 'getDefinition' | Out-Null
        $r2 = Invoke-FabricRest -Token $Token -Method GET -Path "$($r.OperationLocation)/result"
        return $r2.Body
    }
    return $r.Body
}

function Get-ModelBim {
    param($Def)
    $part = $Def.definition.parts | Where-Object { $_.path -eq 'model.bim' } | Select-Object -First 1
    if (-not $part) { throw "model.bim not found in definition" }
    $bytes = [Convert]::FromBase64String($part.payload)
    return ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)
}

function Build-Elements {
    param($Bim)
    $elements = @()
    foreach ($t in $Bim.model.tables) {
        if ($t.name -like 'DateTableTemplate*') { continue }
        if ($t.name -like 'LocalDateTable*')    { continue }
        $children = @()
        if ($t.columns) {
            foreach ($c in $t.columns) {
                if ($c.isHidden) { continue }
                if ($c.type -eq 'rowNumber') { continue }
                $children += [ordered]@{
                    id           = $c.lineageTag
                    is_selected  = $true
                    display_name = $c.name
                    type         = 'semantic_model.column'
                    data_type    = (ConvertTo-AgentDataType $c.dataType)
                    description  = $null
                    children     = @()
                }
            }
        }
        if ($t.measures) {
            foreach ($m in $t.measures) {
                $children += [ordered]@{
                    id           = $m.lineageTag
                    is_selected  = $true
                    display_name = $m.name
                    type         = 'semantic_model.measure'
                    data_type    = (Get-MeasureDataType -Name $m.name)
                    description  = $(if ($m.description) { ($m.description -join ' ') } else { $null })
                    children     = @()
                }
            }
        }
        $tDesc = if ($t.description) { ($t.description -join ' ') } else { $null }
        $elements += [ordered]@{
            id           = $t.lineageTag
            is_selected  = $true
            display_name = $t.name
            type         = 'semantic_model.table'
            description  = $tDesc
            children     = $children
        }
    }
    return $elements
}

function Build-Relationships {
    param($Bim)
    $rels = @()
    if (-not $Bim.model.relationships) { return '[]' }
    foreach ($r in $Bim.model.relationships) {
        $card = 'ManyToOne'
        $rels += [ordered]@{
            FromTable       = $r.fromTable
            FromColumn      = $r.fromColumn
            ToTable         = $r.toTable
            ToColumn        = $r.toColumn
            IsActive        = -not ($r.isActive -eq $false)
            IsBidirectional = ($r.crossFilteringBehavior -eq 'bothDirections')
            Cardinality     = $card
        }
    }
    return ($rels | ConvertTo-Json -Depth 10 -Compress)
}

function Build-AgentDefinitionParts {
    param(
        [string]$DisplayName,
        [string]$ModelDisplayName,
        [string]$WorkspaceId,
        [string]$ModelId,
        $Elements,
        [string]$CsdlRelsJson
    )

    $dataAgent = @{ '$schema' = 'https://developer.microsoft.com/json-schemas/fabric/item/dataAgent/definition/dataAgent/2.1.0/schema.json' }
    $stageCfg  = @{ '$schema' = 'https://developer.microsoft.com/json-schemas/fabric/item/dataAgent/definition/stageConfiguration/1.0.0/schema.json'; aiInstructions = $null }
    $dataSrc   = [ordered]@{
        '$schema'              = 'https://developer.microsoft.com/json-schemas/fabric/item/dataAgent/definition/dataSource/1.0.0/schema.json'
        artifactId             = $ModelId
        workspaceId            = $WorkspaceId
        dataSourceInstructions = $null
        displayName            = $ModelDisplayName
        type                   = 'semantic_model'
        userDescription        = $null
        metadata               = @{ csdl_relationships = $CsdlRelsJson }
        elements               = $Elements
    }

    $parts = @(
        @{ path = 'Files/Config/data_agent.json'; payloadType = 'InlineBase64'; payload = (
            [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($dataAgent | ConvertTo-Json -Depth 5))))
        }
        @{ path = 'Files/Config/draft/stage_config.json'; payloadType = 'InlineBase64'; payload = (
            [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($stageCfg | ConvertTo-Json -Depth 5))))
        }
        @{ path = "Files/Config/draft/semantic-model-$ModelDisplayName/datasource.json"; payloadType = 'InlineBase64'; payload = (
            [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($dataSrc | ConvertTo-Json -Depth 20))))
        }
    )
    return $parts
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
$tok = Get-FabricToken
$ws = (Invoke-FabricRest -Token $tok -Method GET -Path '/workspaces').Body.value | Where-Object { $_.displayName -like 'cts-rtl-3-gold-*' } | Select-Object -First 1
if (-not $ws) { throw "gold workspace not found" }
$wsId = $ws.id
Write-Host "Gold ws: $($ws.displayName) ($wsId)" -ForegroundColor Cyan

$items = (Invoke-FabricRest -Token $tok -Method GET -Path "/workspaces/$wsId/items").Body.value
$smRetail = $items | Where-Object { $_.type -eq 'SemanticModel' -and $_.displayName -eq 'Retail Sales'    } | Select-Object -First 1
$smHr     = $items | Where-Object { $_.type -eq 'SemanticModel' -and $_.displayName -eq 'HR & Workforce' } | Select-Object -First 1

# Delete any existing data agents in the workspace so this script is idempotent
$existingAgents = $items | Where-Object { $_.type -eq 'DataAgent' }
foreach ($a in $existingAgents) {
    Write-Host "Deleting existing DataAgent '$($a.displayName)' ($($a.id))" -ForegroundColor DarkYellow
    Invoke-FabricRest -Token $tok -Method DELETE -Path "/workspaces/$wsId/items/$($a.id)" | Out-Null
}

$targets = @(
    @{ agent='Retail Sales agent'; model=$smRetail }
    @{ agent='HR & Workforce agent'; model=$smHr     }
)

foreach ($t in $targets) {
    $m = $t.model
    Write-Host ""
    Write-Host "Building agent '$($t.agent)' for model '$($m.displayName)' ($($m.id))" -ForegroundColor Cyan
    $def = Get-SemanticModelDefinition -Token $tok -WorkspaceId $wsId -ModelId $m.id
    $bim = Get-ModelBim -Def $def
    $elements = Build-Elements -Bim $bim
    $rels     = Build-Relationships -Bim $bim
    $parts    = Build-AgentDefinitionParts -DisplayName $t.agent -ModelDisplayName $m.displayName -WorkspaceId $wsId -ModelId $m.id -Elements $elements -CsdlRelsJson $rels

    $body = @{
        displayName = $t.agent
        type        = 'DataAgent'
        definition  = @{ parts = $parts }
    }
    $r = Invoke-FabricRest -Token $tok -Method POST -Path "/workspaces/$wsId/items" -Body $body
    if ($r.OperationLocation) {
        $op = Wait-FabricOperation -Token $tok -OperationLocation $r.OperationLocation -Label "create $($t.agent)"
        Write-Host "  created" -ForegroundColor Green
    } else {
        Write-Host "  id=$($r.Body.id)" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
